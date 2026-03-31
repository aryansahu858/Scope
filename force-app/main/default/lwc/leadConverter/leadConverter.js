/**
 * @component     LeadConverter
 * @description   Custom Lead conversion component that replaces the standard
 *                Salesforce Lead conversion flow. Supports two entry points:
 *
 *                  1. QUICK ACTION — The user clicks the "Convert Lead" button
 *                     in the record action bar. Salesforce calls invoke(), which
 *                     flags this instance as the Quick Action instance, dismisses
 *                     the action panel, and updates Lead_Status__c to 'Converted'.
 *                     The record page layout instance then detects the status change
 *                     via its @wire handler and opens the modal at the correct DOM level.
 *
 *                  2. INLINE EDIT / STANDARD UI — The user manually sets
 *                     Lead_Status__c to 'Converted' on the record page. The @wire
 *                     handler on the layout instance intercepts this change and
 *                     opens the conversion modal automatically.
 *
 *                On cancel, the component reverts Lead_Status__c to its previous
 *                value so the Lead is never left in a 'Converted' state without
 *                a completed conversion. On success, the user is navigated to
 *                the newly created Account record.
 *
 * @extends       NavigationMixin(LightningElement)
 * @author        Aryan Sahu
 */

import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues }        from 'lightning/uiObjectInfoApi'; // NEW: for dynamic Stage picklist
import { ShowToastEvent }                          from 'lightning/platformShowToastEvent';
import { NavigationMixin }                         from 'lightning/navigation';
import { CloseActionScreenEvent }                  from 'lightning/actions';

// ── Apex Method Imports ────────────────────────────────────────────────────────
// All server-side operations are delegated to LeadConverterController.
import getLead        from '@salesforce/apex/LeadConverterController.getLead';
import searchAccounts from '@salesforce/apex/LeadConverterController.searchAccounts';
import searchContacts from '@salesforce/apex/LeadConverterController.searchContacts';
import convertLead    from '@salesforce/apex/LeadConverterController.convertLead';

// ── Schema Imports — Lead ──────────────────────────────────────────────────────
// Using schema tokens ensures field references remain valid after package
// upgrades or namespace changes.
import ID_FIELD        from '@salesforce/schema/Lead__c.Id';
import STATUS_FIELD    from '@salesforce/schema/Lead__c.Lead_Status__c';
import CONVERTED_FIELD from '@salesforce/schema/Lead__c.Has_Converted__c';

// ── Schema Imports — Opportunity (for dynamic Stage picklist) ──────────────────
// OPPORTUNITY_OBJECT and STAGE_FIELD are passed to the uiObjectInfoApi wire
// adapters so the platform returns live picklist values from the org's metadata.
// This means adding, renaming, or reordering Stage picklist values in Setup is
// automatically reflected here without any code changes.
import OPPORTUNITY_OBJECT from '@salesforce/schema/Opportunity__c';
import STAGE_FIELD        from '@salesforce/schema/Opportunity__c.Stage__c';

// ── Module-Level Constants ─────────────────────────────────────────────────────
// FIELDS is passed to @wire(getRecord) so the component reactively tracks
// only the two fields it cares about, minimising unnecessary re-renders.
const FIELDS           = [STATUS_FIELD, CONVERTED_FIELD];
const STATUS_CONVERTED = 'Converted'; // Must match the Lead_Status__c picklist value exactly.

// ── SLDS combobox class constants ──────────────────────────────────────────────
// Reused whenever a dropdown needs to be opened or closed. Extracted as constants
// to avoid magic strings being repeated across multiple methods.
const DROPDOWN_CLASS_CLOSED = 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
const DROPDOWN_CLASS_OPEN   = `${DROPDOWN_CLASS_CLOSED} slds-is-open`;

export default class LeadConverter extends NavigationMixin(LightningElement) {

    /** The Id of the Lead__c record currently being viewed. Injected by the platform. */
    @api recordId;

    // ── Reactive UI State ──────────────────────────────────────────────────────
    // @track is used so that deep mutations (e.g. replacing an array) trigger
    // a template re-render.
    @track isModalOpen   = false; // Controls whether the conversion modal is visible.
    @track isProcessing  = false; // Disables the Convert button and shows loading state.
    @track errorMessage  = '';   // Inline validation or server error shown inside the modal.

    /**
     * Set to true once the Apex conversion succeeds.
     * Prevents closeModal() from calling revertStatus() after a successful save,
     * since the status has intentionally moved to 'Converted' by that point.
     */
    isConvertingSuccess = false;

    /**
     * Stores the Lead's status value BEFORE it became 'Converted'.
     * Used by revertStatus() to restore the record if the user cancels.
     * Populated by the @wire handler on every fire where status !== 'Converted'.
     */
    originalStatus;

    /**
     * Distinguishes the Quick Action component instance from the record page
     * layout instance. Both instances share the same class but serve different
     * roles on the page:
     *
     *   Quick Action instance  — lives inside the action panel DOM; should NEVER
     *                            open the modal (would overlap the compact layout).
     *                            invoke() sets this flag to true.
     *
     *   Layout instance        — lives at page level; is the only instance that
     *                            should open the modal.
     *
     * The @wire handler checks this flag before calling openModal(), ensuring
     * only the layout instance ever renders the modal.
     */
    isQuickActionInstance = false;

    // ── Account Conversion State ───────────────────────────────────────────────
    // Default is 'existing' so the user is immediately prompted to search for
    // an existing Account when the modal opens, which is the most common scenario.
    selectedAccountOption = 'existing'; // 'new' | 'existing'
    accountName           = '';         // Name for a newly created Account.
    existingAccountId     = '';         // Salesforce Id of a chosen existing Account.
    selectedAccountName   = '';         // Display name shown in the search input / pill.
    accSearchResults      = [];         // Array of Account records returned by searchAccounts().

    // ── Contact Conversion State ───────────────────────────────────────────────
    // Default is 'existing' so the user is immediately prompted to search for
    // an existing Contact when the modal opens, which is the most common scenario.
    selectedContactOption = 'existing'; // 'new' | 'existing'
    contactFirstName      = '';         // First name for a newly created Contact.
    contactLastName       = '';         // Last name for a newly created Contact (required).
    existingContactId     = '';         // Salesforce Id of a chosen existing Contact.
    selectedContactName   = '';         // Display name shown in the search input / pill.
    conSearchResults      = [];         // Array of Contact records returned by searchContacts().

    // ── Opportunity Conversion State ───────────────────────────────────────────
    doNotCreateOpp = false; // When true, the Opportunity section is skipped.
    oppName        = '';    // Pre-filled from Lead Company name.
    oppCloseDate   = '';    // Defaults to 30 days from today.
    oppStage       = '';    // Set dynamically once stageOptions resolves (see wire below).

    // ── Lookup Dropdown CSS State ──────────────────────────────────────────────
    // These strings drive the SLDS combobox open/closed state via class binding.
    accDropdownClass = DROPDOWN_CLASS_CLOSED;
    conDropdownClass = DROPDOWN_CLASS_CLOSED;

    /**
     * Holds the recordTypeId for Opportunity__c, resolved by the getObjectInfo wire.
     * Required as a dependency by the getPicklistValues wire adapter — it will not
     * fire until this value is available.
     */
    opportunityRecordTypeId;

    /**
     * Timer reference for the debounced search handler.
     * Cleared and reset on every keystroke to avoid firing Apex on every character.
     */
    searchTimeout;


    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Radio button options shared by both the Account and Contact toggle groups.
     * "Select Existing" is the default selection for both sections, since the most
     * common conversion scenario involves linking to records that already exist in the org.
     */
    get options() {
        return [
            { label: 'Create New',      value: 'new'      },
            { label: 'Select Existing', value: 'existing' }
        ];
    }

    /**
     * Stage picklist options for the Opportunity stage combobox.
     * Built dynamically from the getPicklistValues wire response so that any
     * changes made to Opportunity__c.Stage__c in Setup are reflected automatically
     * without requiring a code change or deployment.
     * Returns an empty array while the wire is still loading.
     */
    get stageOptions() {
        return this._stageOptions || [];
    }

    /** True when the user has chosen to create a new Account during conversion. */
    get isCreateAccount() { return this.selectedAccountOption === 'new'; }

    /** True when the user has chosen to create a new Contact during conversion. */
    get isCreateContact() { return this.selectedContactOption === 'new'; }

    /**
     * Drives the aria-expanded attribute on the Account combobox.
     * Returns true when search results are available and the dropdown is open.
     */
    get isAccDropdownOpen() { return this.accSearchResults.length > 0; }

    /**
     * Drives the aria-expanded attribute on the Contact combobox.
     * Returns true when search results are available and the dropdown is open.
     */
    get isConDropdownOpen() { return this.conSearchResults.length > 0; }


    // ═══════════════════════════════════════════════════════════════════════════
    // WIRE ADAPTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @wire getRecord
     * Reactively tracks Lead_Status__c and Has_Converted__c on the current record.
     *
     * Responsibilities:
     *   - Keeps originalStatus up to date with the last non-'Converted' status value,
     *     so revertStatus() always has a valid target to roll back to.
     *   - Opens the conversion modal when all of the following are true:
     *       • Lead_Status__c has been set to 'Converted'
     *       • Has_Converted__c is still false (Lead not yet fully converted)
     *       • The modal is not already open (prevents duplicate modals)
     *       • The conversion has not already succeeded in this session
     *       • This is NOT the Quick Action instance (prevents overlap with compact layout)
     *
     * The isQuickActionInstance guard is the key to preventing a double-modal scenario.
     * When the user clicks the Quick Action button, invoke() sets Lead_Status__c to
     * 'Converted', which causes this wire to fire on BOTH the Quick Action instance
     * AND the layout instance simultaneously. Without the guard, both would call
     * openModal(). With it, only the layout instance proceeds.
     */
    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ error, data }) {
        if (data) {
            const status      = getFieldValue(data, STATUS_FIELD);
            const isConverted = getFieldValue(data, CONVERTED_FIELD);

            // Always track the last known non-'Converted' status so we can
            // restore it if the user cancels the conversion modal.
            if (status !== STATUS_CONVERTED) {
                this.originalStatus = status;
            }

            const shouldOpenModal =
                status === STATUS_CONVERTED &&
                !isConverted              && // Lead has not been fully converted yet.
                !this.isModalOpen         && // Avoid opening a second modal.
                !this.isConvertingSuccess && // Avoid re-opening after a successful save.
                !this.isQuickActionInstance; // Only the layout instance opens the modal.

            if (shouldOpenModal) {
                this.openModal();
            }
        } else if (error) {
            console.error('[LeadConverter] wiredRecord error:', error);
        }
    }

    /**
     * @wire getObjectInfo
     * Fetches metadata for Opportunity__c to obtain the default record type Id.
     * The record type Id is required by getPicklistValues as a mandatory parameter —
     * the picklist wire adapter will not fire until this value is available.
     *
     * In orgs without multiple record types, defaultRecordTypeId returns the
     * Master record type Id, which is always valid.
     */
    @wire(getObjectInfo, { objectApiName: OPPORTUNITY_OBJECT })
    wiredObjectInfo({ error, data }) {
        if (data) {

            const recordTypeInfos = data.recordTypeInfos;

            // Loop through record types and find Pre_Sales
            this.opportunityRecordTypeId = Object.keys(recordTypeInfos)
                .find(rtId => recordTypeInfos[rtId].name === 'Pre - Sales');


        } else if (error) {
            console.error('[LeadConverter] getObjectInfo error:', error);
        }
    }

    /**
     * @wire getPicklistValues
     * Fetches the active picklist values for Opportunity__c.Stage__c from org metadata.
     * Fires reactively once opportunityRecordTypeId is populated by the getObjectInfo wire.
     *
     * The response is mapped into the { label, value } shape expected by
     * lightning-combobox and stored in _stageOptions. The stageOptions getter
     * exposes this array to the template.
     *
     * oppStage is also initialised here to the first available picklist value
     * so the combobox always has a valid default selection when the modal opens.
     */
    @wire(getPicklistValues, {
        recordTypeId: '$opportunityRecordTypeId',
        fieldApiName: STAGE_FIELD
    })
    wiredStagePicklist({ error, data }) {
        if (data) {
            // Map platform picklist values to the { label, value } shape
            // required by lightning-combobox options.
            this._stageOptions = data.values.map(({ label, value }) => ({ label, value }));

            // Default the stage selector to the first active picklist value
            // so the field is never left blank when the modal opens.
            if (this._stageOptions.length > 0 && !this.oppStage) {
                this.oppStage = this._stageOptions[0].value;
            }
        } else if (error) {
            console.error('[LeadConverter] getPicklistValues error:', error);
        }
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // QUICK ACTION ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @api invoke
     * Called automatically by the Salesforce platform when the "Convert Lead"
     * Quick Action button is clicked on the record page.
     *
     * Why we update the status here instead of calling openModal() directly:
     * This component instance lives inside the Quick Action panel DOM context.
     * Any modal it renders is scoped to that panel and will overlap the page's
     * compact layout, producing a broken visual experience.
     *
     * By updating Lead_Status__c to 'Converted', we delegate modal rendering to
     * the layout instance of this component (which always exists at page level),
     * ensuring the modal appears in the correct DOM context.
     *
     * Flow:
     *   1. Mark this instance as the Quick Action instance → wire will skip openModal().
     *   2. Dispatch CloseActionScreenEvent → dismisses the Quick Action panel.
     *   3. Update Lead_Status__c to 'Converted' → triggers the layout instance's
     *      @wire handler, which opens the modal at the correct DOM level.
     */
    @api invoke() {
        this.isQuickActionInstance = true;                    // Silence this instance's wire.
        this.dispatchEvent(new CloseActionScreenEvent());     // Close the Quick Action panel.

        const fields = {};
        fields[ID_FIELD.fieldApiName]     = this.recordId;
        fields[STATUS_FIELD.fieldApiName] = STATUS_CONVERTED;

        updateRecord({ fields })
            .catch(error => {

                if(error.body.output.errors[0].message) {
                    this.showToast('Error', error.body.output.errors[0].message, 'error');
                }
                else{
                    this.showToast('Error', 'Could not initiate Lead conversion', 'error');
                }

                console.error('[LeadConverter] invoke() updateRecord error:', error.body.output.errors[0].message);
            });
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // MODAL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Opens the conversion modal and pre-populates fields from the Lead record.
     * Only called on the layout instance (never the Quick Action instance).
     *
     * The accountName guard ensures the Apex call is made only once per page load.
     * If the user closes and re-opens the modal without refreshing, the previously
     * fetched values are reused, avoiding unnecessary server round-trips.
     *
     * Note: selectedAccountOption and selectedContactOption are intentionally NOT
     * reset here so that if the user re-opens the modal the UI stays in the state
     * they last left it. Their defaults ('existing') are set at property declaration.
     */
    async openModal() {
        this.isModalOpen         = true;
        this.isConvertingSuccess = false;
        this.errorMessage        = '';

        try {
            if (!this.accountName) {
                const lead = await getLead({ leadId: this.recordId });

                // Pre-fill form fields using Lead data.
                this.accountName     = lead.Company__c;
                this.contactLastName = lead.Name;
                // Opportunity name defaults to "<Company>-" as a starting point.
                this.oppName = lead.Company__c ? `${lead.Company__c}-` : '';

                // Default close date is 30 days from today.
                const today = new Date();
                today.setDate(today.getDate() + 30);
                this.oppCloseDate = today.toISOString().split('T')[0];
            }
        } catch (err) {
            this.showToast('Error', 'Could not load Lead defaults', 'error');
            console.error('[LeadConverter] openModal() getLead error:', err);
        }
    }

    /**
     * Closes the modal. If the conversion did not complete successfully,
     * the Lead's status is rolled back to its original value to prevent
     * the record from being left in an unconverted 'Converted' state.
     */
    closeModal() {
        this.isModalOpen = false;
        if (!this.isConvertingSuccess) {
            this.revertStatus();
        }
    }

    /**
     * Reverts Lead_Status__c to the value it held before the user initiated
     * conversion. This is triggered when the user cancels the modal.
     *
     * The guard on originalStatus prevents an unnecessary DML operation in the
     * unlikely edge case where the wire has not yet resolved when the user cancels.
     */
    revertStatus() {
        if (!this.originalStatus) return;

        this.isProcessing = true;

        const fields = {};
        fields[ID_FIELD.fieldApiName]     = this.recordId;
        fields[STATUS_FIELD.fieldApiName] = this.originalStatus;

        updateRecord({ fields })
            .then(() => {
                this.showToast('Cancelled', `Status reverted to ${this.originalStatus}`, 'info');
            })
            .catch(error => {
                this.showToast('Error', 'Failed to revert status', 'error');
                console.error('[LeadConverter] revertStatus() error:', error);
            })
            .finally(() => {
                this.isProcessing = false;
            });
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // CORE CONVERSION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Validates user input, builds the conversion payload, and calls the Apex
     * convertLead method. On success, navigates to the new Account record.
     * On failure, displays an inline error without closing the modal.
     */
    handleConvert() {
        if (!this.validateInputs()) return;

        this.isProcessing = true;

        // Build a structured payload that maps directly to the Apex wrapper class.
        const payload = {
            leadId            : this.recordId,
            createAccount     : this.isCreateAccount,
            accountDetails    : { name: this.accountName },
            existingAccountId : this.existingAccountId,
            createContact     : this.isCreateContact,
            existingContactId : this.existingContactId,
            contactDetails    : { firstName: this.contactFirstName, lastName: this.contactLastName },
            createOpportunity : !this.doNotCreateOpp,
            opportunityDetails: { name: this.oppName, closeDate: this.oppCloseDate, stageName: this.oppStage}
        };

        convertLead({ payload })
            .then(result => {
                if (result.success) {
                    this.isConvertingSuccess = true;
                    this.showToast('Success', 'Lead Converted Successfully', 'success');
                    this.isModalOpen = false;

                    // Navigate to the newly created Account record after conversion.
                    this[NavigationMixin.Navigate]({
                        type: 'standard__recordPage',
                        attributes: {
                            recordId     : result.accountId,
                            objectApiName: 'Account',
                            actionName   : 'view'
                        }
                    });
                } else {
                    // Apex returned a handled error (e.g. duplicate detection).
                    // Display inline without closing the modal so the user can correct it.
                    this.errorMessage = result.error;
                }
            })
            .catch(error => {
                // Unhandled Apex exception or network failure.
                this.errorMessage = error.body?.message || error.message;
            })
            .finally(() => {
                // Only clear the processing state if we are NOT navigating away.
                // If isConvertingSuccess is true, the component is being destroyed
                // by navigation, so updating state would be a no-op at best.
                if (!this.isConvertingSuccess) this.isProcessing = false;
            });
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // INPUT & OPTION CHANGE HANDLERS
    // ═══════════════════════════════════════════════════════════════════════════

    /** Switches the Account section between "Create New" and "Select Existing". */
    handleAccountOptionChange(e) { this.selectedAccountOption = e.detail.value; }

    /** Switches the Contact section between "Create New" and "Select Existing". */
    handleContactOptionChange(e) { this.selectedContactOption = e.detail.value; }

    /** Toggles whether the Opportunity section should be skipped on conversion. */
    handleOppCheckboxChange(e)   { this.doNotCreateOpp = e.target.checked; }

    /**
     * Generic field change handler shared across all text/date/combobox inputs.
     * Each input carries a data-id attribute that maps to a specific component property,
     * avoiding the need for individual handlers per field.
     *
     * @param {Event} event - The change event from a lightning-input or lightning-combobox.
     */
    handleInputChange(event) {
        const field = event.target.dataset.id;
        const val   = event.target.value;

        if      (field === 'accName')  this.accountName     = val;
        else if (field === 'conFirst') this.contactFirstName = val;
        else if (field === 'conLast')  this.contactLastName  = val;
        else if (field === 'oppName')  this.oppName          = val;
        else if (field === 'oppDate')  this.oppCloseDate     = val;
        else if (field === 'oppStage') this.oppStage         = val;
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // LOOKUP SEARCH — ACCOUNT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Captures the current search term for Accounts and triggers a debounced search.
     * Updating selectedAccountName on every keystroke keeps the input value in sync.
     */
    handleAccountSearchKeyChange(event) {
        this.selectedAccountName = event.target.value;
        this.debouncedSearch(event.target.value, 'Account');
    }

    /**
     * Fires the Apex Account search and opens the dropdown if results are returned.
     * @param {string} key - The search term typed by the user.
     */
    executeAccountSearch(key) {
        searchAccounts({ searchTerm: key })
            .then(res => {
                this.accSearchResults = res;
                this.accDropdownClass = res.length > 0 ? DROPDOWN_CLASS_OPEN : DROPDOWN_CLASS_CLOSED;
            });
    }

    /**
     * Confirms the Account selection from the dropdown results.
     * Stores the record Id and display name, then closes the dropdown.
     * The template will replace the search input with a selection pill.
     */
    selectAccount(event) {
        this.existingAccountId   = event.currentTarget.dataset.id;
        this.selectedAccountName = event.currentTarget.dataset.name;
        this.accDropdownClass    = DROPDOWN_CLASS_CLOSED;
    }

    /**
     * Clears the current Account selection, allowing the user to search again.
     * Called when the user clicks the remove (×) button on the selection pill.
     */
    clearAccount() {
        this.existingAccountId   = '';
        this.selectedAccountName = '';
        this.accSearchResults    = [];
        this.accDropdownClass    = DROPDOWN_CLASS_CLOSED;
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // LOOKUP SEARCH — CONTACT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Captures the current search term for Contacts and triggers a debounced search.
     * Updating selectedContactName on every keystroke keeps the input value in sync.
     */
    handleContactSearchKeyChange(event) {
        this.selectedContactName = event.target.value;
        this.debouncedSearch(event.target.value, 'Contact');
    }

    /**
     * Fires the Apex Contact search and opens the dropdown if results are returned.
     * @param {string} key - The search term typed by the user.
     */
    executeContactSearch(key) {
        searchContacts({ searchTerm: key })
            .then(res => {
                this.conSearchResults = res;
                this.conDropdownClass = res.length > 0 ? DROPDOWN_CLASS_OPEN : DROPDOWN_CLASS_CLOSED;
            });
    }

    /**
     * Confirms the Contact selection from the dropdown results.
     * Stores the record Id and display name, then closes the dropdown.
     * The template will replace the search input with a selection pill.
     */
    selectContact(event) {
        this.existingContactId   = event.currentTarget.dataset.id;
        this.selectedContactName = event.currentTarget.dataset.name;
        this.conDropdownClass    = DROPDOWN_CLASS_CLOSED;
    }

    /**
     * Clears the current Contact selection, allowing the user to search again.
     * Called when the user clicks the remove (×) button on the selection pill.
     */
    clearContact() {
        this.existingContactId   = '';
        this.selectedContactName = '';
        this.conSearchResults    = [];
        this.conDropdownClass    = DROPDOWN_CLASS_CLOSED;
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Debounces Apex search calls to avoid firing on every keystroke.
     * The search only executes after the user pauses typing for 300ms.
     * If the input is cleared or reduced to a single character, results
     * are cleared immediately without waiting for the timer.
     *
     * @param {string} key  - The current search term.
     * @param {string} type - 'Account' or 'Contact' — determines which Apex method to call.
     */
    debouncedSearch(key, type) {
        window.clearTimeout(this.searchTimeout);

        if (key.length > 1) {
            this.searchTimeout = setTimeout(() => {
                if (type === 'Account') this.executeAccountSearch(key);
                if (type === 'Contact') this.executeContactSearch(key);
            }, 300);
        } else {
            // Input is too short — clear stale results immediately.
            this.clearSearchResults(type);
        }
    }

    /**
     * Clears search results and closes the dropdown for the specified lookup type.
     * Called when the search term drops below the minimum length threshold.
     *
     * @param {string} type - 'Account' or 'Contact'.
     */
    clearSearchResults(type) {
        if (type === 'Account') {
            this.accSearchResults = [];
            this.accDropdownClass = DROPDOWN_CLASS_CLOSED;
        } else {
            this.conSearchResults = [];
            this.conDropdownClass = DROPDOWN_CLASS_CLOSED;
        }
    }

    /**
     * Validates all required fields before allowing the conversion to proceed.
     * Sets an inline errorMessage and returns false on the first failed rule,
     * so the user sees one clear error at a time.
     *
     * Rules:
     *   - Account: name required if creating new; existing Id required if selecting existing.
     *   - Contact: last name required if creating new; existing Id required if selecting existing.
     *   - Opportunity: all three fields required unless "Do not create" is checked.
     *
     * @returns {boolean} true if all validations pass, false otherwise.
     */
    validateInputs() {
        this.errorMessage = '';

        if  (this.isCreateAccount  && !this.accountName)       return this.setValidationError('Account Name is required.');
        if  (!this.isCreateAccount && !this.existingAccountId) return this.setValidationError('Please select an existing account.');
        if  (this.isCreateContact  && !this.contactLastName)   return this.setValidationError('Contact Last Name is required.');
        if  (!this.isCreateContact && !this.existingContactId) return this.setValidationError('Please select an existing contact.');

        if (!this.doNotCreateOpp) {
            if (!this.oppName || !this.oppCloseDate || !this.oppStage) {
                return this.setValidationError('Please fill in all Opportunity fields.');
            }
        }

        return true;
    }

    /**
     * Sets the inline error message and returns false.
     * Designed to be used as a one-liner return inside validateInputs().
     *
     * @param  {string}  msg - The error message to display.
     * @returns {boolean}    Always returns false.
     */
    setValidationError(msg) {
        this.errorMessage = msg;
        return false;
    }

    /**
     * Dispatches a Lightning toast notification.
     *
     * @param {string} title   - Bold heading shown in the toast.
     * @param {string} message - Body text of the toast.
     * @param {string} variant - 'success' | 'error' | 'warning' | 'info'
     */
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}