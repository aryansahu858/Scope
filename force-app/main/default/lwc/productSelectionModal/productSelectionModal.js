import { LightningElement, track, api } from 'lwc';
import getProducts from '@salesforce/apex/ProductController.getProducts';
import getRelatedQuoteProducts from '@salesforce/apex/ProductController.getRelatedQuoteProducts';
import getVariantData from '@salesforce/apex/ProductController.getVariantData';
import validateAndConvertPrice from '@salesforce/apex/ProductController.validateAndConvertPrice';
import upsertQuoteLineItems from '@salesforce/apex/ProductController.upsertQuoteLineItems';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const DEBOUNCE_DELAY = 300;
const MAX_RESULTS = 100;

export default class ProductSelectionModal extends LightningElement {
    
    _recordId;

    @api 
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadInitialData(); // ENHANCEMENT 3: Load existing data
        }
    }
    get recordId() {
        return this._recordId;
    }

    @track isStepOne = true;
    @track isStep3 = false;
    
    @track allProducts = [];
    @track filteredProducts = [];
    @track existingLineItems = []; // ENHANCEMENT 3 state
    @track selectedIds = new Set();
    @track searchTerm = '';
    @track isLoading = true;

    @track configuredProducts = [];
    @track step3Data = [];
    @track isCreating = false;

    _debounceTimer = null;
    _escListener = null;

    columns = [
        { label: 'Product Name', fieldName: 'Name', type: 'text', sortable: true, wrapText: true },
        { label: 'Product Code', fieldName: 'Product_Code__c', type: 'text' },
        { label: 'Product Family', fieldName: 'Product_Family__c', type: 'text' },
        { label: 'Description', fieldName: 'Product_Description__c', type: 'text', wrapText: true }
    ];

    connectedCallback() {
        this._escListener = this.handleKeyDown.bind(this);
        document.addEventListener('keydown', this._escListener);
    }

    disconnectedCallback() {
        if (this._debounceTimer) clearTimeout(this._debounceTimer);
        document.removeEventListener('keydown', this._escListener);
    }

    // ==========================================
    // INITIAL DATA LOAD
    // ==========================================
    async loadInitialData(searchTerm = '') {
        this.isLoading = true;
        try {
            const [prods, qlis] = await Promise.all([
                getProducts({ searchTerm: searchTerm || null, limitSize: MAX_RESULTS, quoteId: this.recordId }),
                getRelatedQuoteProducts({ recordId: this.recordId }) // Load existing
            ]);
            
            this.allProducts = prods || [];
            this.filteredProducts = this.allProducts;
            // Run this only on first load
            if (!searchTerm) {
                this.existingLineItems = qlis || [];
            }
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to fetch data', 'error');
            this.allProducts = [];
            this.filteredProducts = [];
        } finally {
            this.isLoading = false;
        }
    }

    get isReady() { return !this.isLoading; }
    get hasProducts() { return this.filteredProducts && this.filteredProducts.length > 0; }
    get isEmpty() { return !this.isLoading && (!this.filteredProducts || this.filteredProducts.length === 0); }
    get selectedCount() { return this.selectedIds.size; }
    get hasSelections() { return this.selectedIds.size > 0; }
    get isNextDisabled() { 
        // Allow next if there are existing items OR new selections
        return this.selectedIds.size === 0 && this.existingLineItems.length === 0; 
    }
    get selectedIdsArray() { return Array.from(this.selectedIds); }

    handleSearchInput(event) {
        this.searchTerm = event.target.value;
        if (this._debounceTimer) clearTimeout(this._debounceTimer);
        this._debounceTimer = setTimeout(() => {
            const term = this.searchTerm.trim();
            if (term.length === 0) {
                this.filteredProducts = this.allProducts;
                return;
            }
            if (term.length >= 2) {
                this.loadInitialData(term);
            } else {
                this.applyClientFilter(term);
            }
        }, DEBOUNCE_DELAY);
    }

    applyClientFilter(term) {
        const lower = term.toLowerCase();
        this.filteredProducts = this.allProducts.filter(p =>
            (p.Name || '').toLowerCase().includes(lower) ||
            (p.Product_Code__c || '').toLowerCase().includes(lower) ||
            (p.Product_Family__c || '').toLowerCase().includes(lower)
        );
    }

    handleRowSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedIds = new Set(rows.map(r => r.Id));
    }

    // ==========================================
    // TRANSITION TO STEP 2
    // ==========================================
    async handleNext() {
        this.isStepOne = false;
        this.isLoading = true;

        try {
            const selectedProductRecords = this.allProducts.filter(p => this.selectedIds.has(p.Id));
            const existingProdIds = this.existingLineItems.map(q => q.Product__c);
            
            // Combine IDs to fetch all relevant variants
            const allProdIds = Array.from(new Set([...this.selectedIdsArray, ...existingProdIds]));
            const variants = await getVariantData({ productIds: allProdIds });
            
            this.buildConfigurationData(selectedProductRecords, this.existingLineItems, variants);
        } catch (error) {
            console.error('Error fetching variants', error);
            this.showToast('Error', 'Failed to fetch variant data.', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    buildConfigurationData(selectedProducts, existingQLIs, variants) {
        let items = [];
        let rowCounter = 0;

        // 1. Map Existing QLIs (Enhancement 3)
        existingQLIs.forEach(qli => {
            const prodVariants = variants.filter(v => v.Product__c === qli.Product__c);
            const configFields = this.generateConfigFields(prodVariants, qli.Product_Variant_Master__r);

            items.push({
                rowId: `row-${rowCounter++}`, // Unique identifier per row
                id: qli.Product__c,
                name: qli.Product__r?.Name,
                hasVariants: prodVariants.length > 0,
                isGetPriceDisabled: !(prodVariants.length > 0),
                variants: prodVariants,
                configFields: configFields,
                price: qli.List_Price__c, // ENHANCEMENT 1
                currencyCode: null, 
                isPriceValid: true, // Valid by default since it exists
                variantId: qli.Product_Variant_Master__c, // ENHANCEMENT 2
                qliId: qli.Id, // Track existing ID for update
                quantity: qli.Quantity__c || 1,
                discountPct: qli.Discount_Percent__c || 0,
                upliftPct: qli.Uplift_Percent__c || 0,
                gstPct: qli.GST_Percent__c || 0
            });
        });

        // 2. Map Newly Selected Products
        selectedProducts.forEach(prod => {
            const prodVariants = variants.filter(v => v.Product__c === prod.Id);
            const configFields = this.generateConfigFields(prodVariants, null);

            items.push({
                rowId: `row-${rowCounter++}`,
                id: prod.Id,
                name: prod.Name,
                hasVariants: prodVariants.length > 0,
                isGetPriceDisabled: !(prodVariants.length > 0),
                variants: prodVariants,
                configFields: configFields,
                price: null,
                currencyCode: null,
                isPriceValid: false,
                variantId: null,
                qliId: null,
                quantity: 1,
                discountPct: 0,
                upliftPct: 0,
                gstPct: 0
            });
        });

        this.configuredProducts = items;
    }

    generateConfigFields(prodVariants, existingVariantRecord) {
        let configFields = [];
        for (let i = 1; i <= 10; i++) {
            const fieldName = `Config_Opt_${i}__c`;
            const uniqueVals = new Set();
            prodVariants.forEach(v => {
                if (v[fieldName]) uniqueVals.add(v[fieldName]);
            });

            const hasOptions = uniqueVals.size > 0;
            const isSingleOption = uniqueVals.size === 1;
            const optionsArr = Array.from(uniqueVals);

            let preselectedValue = '';
            if (existingVariantRecord && existingVariantRecord[fieldName]) {
                preselectedValue = existingVariantRecord[fieldName];
            } else if (isSingleOption) {
                preselectedValue = optionsArr[0];
            }

            configFields.push({
                name: fieldName,
                label: `Config Option ${i}`,
                options: hasOptions ? optionsArr.map(val => ({ label: val, value: val })) : [],
                selectedValue: preselectedValue,
                isDisabled: !hasOptions
            });
        }
        return configFields;
    }

    // ==========================================
    // STEP 2: CONFIGURATION & PRICING
    // ==========================================
    get isStepTwo() {
        return !this.isStepOne && !this.isStep3;
    }
    get isStepThree() {
        return this.isStep3;
    }
    get isStep2NextDisabled() {
        return !this.configuredProducts.some(p => p.isPriceValid);
    }

    handleConfigChange(event) {
        const rowId = event.target.dataset.rowid;
        const fieldName = event.target.dataset.fieldname;
        const value = event.target.value;

        const prodIndex = this.configuredProducts.findIndex(p => p.rowId === rowId);
        if (prodIndex > -1) {
            const fieldIndex = this.configuredProducts[prodIndex].configFields.findIndex(f => f.name === fieldName);
            if (fieldIndex > -1) {
                this.configuredProducts[prodIndex].configFields[fieldIndex].selectedValue = value;
                // Invalidate pricing if config changes
                this.configuredProducts[prodIndex].isPriceValid = false;
                this.configuredProducts[prodIndex].price = null;
                this.configuredProducts[prodIndex].variantId = null;
                this.configuredProducts = [...this.configuredProducts];
            }
        }
    }

    // ENHANCEMENT 1: Editable Unit Price in Step 2
    handleStep2PriceChange(event) {
        const rowId = event.target.dataset.rowid;
        let val = parseFloat(event.target.value);
        if (isNaN(val)) val = 0;

        const prodIndex = this.configuredProducts.findIndex(p => p.rowId === rowId);
        if (prodIndex > -1) {
            this.configuredProducts[prodIndex].price = val;
            this.configuredProducts = [...this.configuredProducts];
        }
    }

    async handleGetPrice(event) {
        const rowId = event.target.dataset.rowid;
        const prodIndex = this.configuredProducts.findIndex(p => p.rowId === rowId);
        const prod = this.configuredProducts[prodIndex];

        const missingConfig = prod.configFields.some(f => !f.isDisabled && !f.selectedValue);
        if (missingConfig) {
            this.showToast('Missing Selections', 'Please select all available configuration options.', 'warning');
            return;
        }

        const match = prod.variants.find(v => {
            return prod.configFields.every(f => {
                if (f.isDisabled) return true; 
                return v[f.name] === f.selectedValue;
            });
        });

        if (match) {
            this.isLoading = true;
            try {
                // ENHANCEMENT 2: Store variant ID
                prod.variantId = match.Id;
                const rspValue = match.RSP__c || 0;
                const rspCurrency = match.CurrencyIsoCode || 'USD';

                const pricingCtx = await validateAndConvertPrice({
                    quoteId: this.recordId,
                    productId: prod.id,
                    rspValue: rspValue,
                    rspCurrency: rspCurrency
                });

                if (pricingCtx.errorMessage) {
                    prod.isPriceValid = false;
                    this.showToast('Pricing Error', pricingCtx.errorMessage, 'error');
                } else if (!pricingCtx.isValidPriceBook) {
                    prod.isPriceValid = false;
                    this.showToast('Error', 'No Price Book Entry available in Opportunity currency', 'error');
                } else {
                    prod.currencyCode = pricingCtx.currencyCode;
                    prod.price = pricingCtx.convertedPrice; // Editable raw value
                    prod.isPriceValid = true;
                }
            } catch (err) {
                console.error(err);
                this.showToast('Error', 'Failed to validate pricing context.', 'error');
            } finally {
                this.isLoading = false;
                this.configuredProducts = [...this.configuredProducts];
            }
        } else {
            prod.isPriceValid = false;
            prod.variantId = null;
            this.configuredProducts = [...this.configuredProducts];
            this.showToast('No Match', 'No pricing found for this exact configuration.', 'error');
        }
    }

    // ==========================================
    // STEP 3: PRICING BREAKDOWN
    // ==========================================
    handleNextToStep3() {
        const validProducts = this.configuredProducts.filter(p => p.isPriceValid);
        
        // Build Step 3 Data Matrix using retained configurations
        this.step3Data = validProducts.map(p => {
            let discountAmt = p.price * (p.discountPct / 100);
            let discountedPrice = p.price - discountAmt;
            let upliftAmt = discountedPrice * (p.upliftPct / 100);
            let finalUnitPrice = discountedPrice + upliftAmt;
            let totalPrice = finalUnitPrice * p.quantity;
            let gstAmt = totalPrice * (p.gstPct / 100);
            let totalLineAmount = totalPrice + gstAmt;

            return {
                rowId: p.rowId,
                id: p.id,
                name: p.name,
                qliId: p.qliId,
                variantId: p.variantId,
                currencyCode: p.currencyCode,
                unitPrice: p.price,
                quantity: p.quantity,
                discountPct: p.discountPct,
                discountAmt: discountAmt,
                upliftPct: p.upliftPct,
                upliftAmt: upliftAmt,
                finalUnitPrice: finalUnitPrice,
                totalPrice: totalPrice,
                gstPct: p.gstPct,
                gstAmt: gstAmt,
                totalLineAmount: totalLineAmount
            };
        });

        this.isStepOne = false;
        this.isStep3 = true;
    }

    // Reactive Math Engine (Enhancement 1 supports Unit Price edits)
    handlePricingChange(event) {
        const rowId = event.target.dataset.rowid;
        const field = event.target.dataset.field;
        let val = parseFloat(event.target.value);
        if (isNaN(val) || val < 0) val = 0;

        const rows = [...this.step3Data];
        const row = rows.find(r => r.rowId === rowId);

        if (row) {
            row[field] = val;

            row.discountAmt = row.unitPrice * (row.discountPct / 100);
            let discountedPrice = row.unitPrice - row.discountAmt;

            row.upliftAmt = discountedPrice * (row.upliftPct / 100);
            row.finalUnitPrice = discountedPrice + row.upliftAmt;

            row.totalPrice = row.finalUnitPrice * row.quantity;

            row.gstAmt = row.totalPrice * (row.gstPct / 100);
            row.totalLineAmount = row.totalPrice + row.gstAmt;
        }
        this.step3Data = rows;
    }

    // ==========================================
    // GLOBAL LOGIC & DML
    // ==========================================
    handleBack() {
        this.isStepOne = true;
    }

    handleBackToStep2() {
        this.isStep3 = false;
        this.isStepOne = false;
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleKeyDown(event) {
        if (event.key === 'Escape') this.handleClose();
    }

    async handleCreate() {
        this.isCreating = true;
        this.isLoading = true;

        const payload = this.step3Data.map(p => ({
            qliId: p.qliId, // Passes existing ID for Update vs Insert
            quoteId: this.recordId,
            productId: p.id,
            variantId: p.variantId,
            unitPrice: p.unitPrice,
            quantity: p.quantity,
            discountPct: p.discountPct,
            discountAmt: p.discountAmt,
            upliftPct: p.upliftPct,
            upliftAmt: p.upliftAmt,
            finalUnitPrice: p.finalUnitPrice,
            totalPrice: p.totalPrice,
            gstPct: p.gstPct,
            gstAmt: p.gstAmt,
            totalLineAmount: p.totalLineAmount
        }));

        console.log('===========================================================');
        console.log(payload);

        try {
            await upsertQuoteLineItems({ lineItems: payload });
            this.showToast('Success', 'Quote Line Items saved successfully.', 'success');
            this.handleClose();
        } catch (error) {
            console.error('Error saving records', error);
            this.showToast('Error', 'Failed to save Quote Line Items.', 'error');
            this.isLoading = false;
            this.isCreating = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}