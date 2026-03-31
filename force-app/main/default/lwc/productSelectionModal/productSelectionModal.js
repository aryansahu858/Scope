import { LightningElement, track, api } from 'lwc';
import getProducts from '@salesforce/apex/ProductController.getProducts';
import getVariantData from '@salesforce/apex/ProductController.getVariantData';
import validateAndConvertPrice from '@salesforce/apex/ProductController.validateAndConvertPrice';
import createQuoteLineItems from '@salesforce/apex/ProductController.createQuoteLineItems';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const DEBOUNCE_DELAY = 300;
const MAX_RESULTS = 100;

export default class ProductSelectionModal extends LightningElement {
    
    // ==========================================
    // RECORD ID GETTER/SETTER (FIX FOR SCRIPT EXCEPTION)
    // ==========================================
    _recordId;

    @api 
    set recordId(value) {
        this._recordId = value;
        // Only fetch products once the recordId is successfully populated by the Quick Action framework
        if (value) {
            this.fetchProducts();
        }
    }
    get recordId() {
        return this._recordId;
    }

    // --- State ---
    @track isStepOne = true;
    @track isStep3 = false;
    
    @track allProducts = [];
    @track filteredProducts = [];
    @track selectedIds = new Set();
    @track searchTerm = '';
    @track isLoading = true;

    @track configuredProducts = [];
    @track step3Data = [];
    @track isCreating = false;

    _debounceTimer = null;
    _escListener = null;

    // Added Description Column
    columns = [
        { label: 'Product Name', fieldName: 'Name', type: 'text', sortable: true, wrapText: true },
        { label: 'Product Code', fieldName: 'Product_Code__c', type: 'text' },
        { label: 'Product Family', fieldName: 'Product_Family__c', type: 'text' },
        { label: 'Description', fieldName: 'Product_Description__c', type: 'text', wrapText: true }
    ];

    connectedCallback() {
        // Removed fetchProducts() from here to prevent querying with null recordId
        this._escListener = this.handleKeyDown.bind(this);
        document.addEventListener('keydown', this._escListener);
    }

    disconnectedCallback() {
        if (this._debounceTimer) clearTimeout(this._debounceTimer);
        document.removeEventListener('keydown', this._escListener);
    }

    // ==========================================
    // STEP 1: PRODUCT SELECTION LOGIC
    // ==========================================
    async fetchProducts(searchTerm = '') {
        this.isLoading = true;
        try {
            // Passing this.recordId for Quote PriceBook filtering
            const data = await getProducts({ searchTerm: searchTerm || null, limitSize: MAX_RESULTS, quoteId: this.recordId });
            this.allProducts = data || [];
            this.filteredProducts = this.allProducts;
        } catch (error) {
            console.error('fetchProducts error', error);
            this.showToast('Error', error.body?.message || 'Failed to fetch products', 'error');
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
    get isNextDisabled() { return this.selectedIds.size === 0; }
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
                this.fetchProducts(term);
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
        if (!this.selectedIds.size) return;
        this.isStepOne = false;
        this.isLoading = true;

        try {
            const selectedProductRecords = this.allProducts.filter(p => this.selectedIds.has(p.Id));
            const variants = await getVariantData({ productIds: this.selectedIdsArray });
            this.buildConfigurationData(selectedProductRecords, variants);
        } catch (error) {
            console.error('Error fetching variants', error);
            this.showToast('Error', 'Failed to fetch variant data.', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    buildConfigurationData(products, variants) {
        this.configuredProducts = products.map(prod => {
            const prodVariants = variants.filter(v => v.Product__c === prod.Id);
            const hasVariants = prodVariants.length > 0;
            
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

                configFields.push({
                    name: fieldName,
                    label: `Config Option ${i}`,
                    options: hasOptions ? optionsArr.map(val => ({ label: val, value: val })) : [],
                    selectedValue: isSingleOption ? optionsArr[0] : '',
                    isDisabled: !hasOptions
                });
            }

            return {
                id: prod.Id,
                name: prod.Name,
                hasVariants: hasVariants,
                isGetPriceDisabled: !hasVariants,
                variants: prodVariants,
                configFields: configFields,
                // Quantity logic removed from Step 2
                price: null,
                currencyCode: null,
                isPriceValid: false,
                displayPrice: null
            };
        });
    }

    // ==========================================
    // STEP 2: CONFIGURATION
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
        const productId = event.target.dataset.productid;
        const fieldName = event.target.dataset.fieldname;
        const value = event.target.value;

        const prodIndex = this.configuredProducts.findIndex(p => p.id === productId);
        if (prodIndex > -1) {
            const fieldIndex = this.configuredProducts[prodIndex].configFields.findIndex(f => f.name === fieldName);
            if (fieldIndex > -1) {
                this.configuredProducts[prodIndex].configFields[fieldIndex].selectedValue = value;
                this.configuredProducts[prodIndex].isPriceValid = false;
                this.configuredProducts[prodIndex].price = null;
                this.configuredProducts[prodIndex].displayPrice = null;
                this.configuredProducts = [...this.configuredProducts];
            }
        }
    }

    async handleGetPrice(event) {
        const productId = event.target.dataset.productid;
        const prodIndex = this.configuredProducts.findIndex(p => p.id === productId);
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
                    prod.displayPrice = null;
                    this.showToast('Pricing Error', pricingCtx.errorMessage, 'error');
                } else if (!pricingCtx.isValidPriceBook) {
                    prod.isPriceValid = false;
                    prod.displayPrice = null;
                    this.showToast('Error', 'No Price Book Entry available for selected product in Opportunity currency', 'error');
                } else {
                    prod.currencyCode = pricingCtx.currencyCode;
                    prod.price = pricingCtx.convertedPrice;
                    // Format for Inline Input
                    prod.displayPrice = new Intl.NumberFormat('en-US', { style: 'currency', currency: prod.currencyCode }).format(prod.price);
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
            prod.displayPrice = null;
            this.configuredProducts = [...this.configuredProducts];
            this.showToast('No Match', 'No pricing found for this exact configuration.', 'error');
        }
    }

    // ==========================================
    // STEP 3: PRICING BREAKDOWN
    // ==========================================
    handleNextToStep3() {
        const validProducts = this.configuredProducts.filter(p => p.isPriceValid);
        
        // Build Step 3 Data Matrix
        this.step3Data = validProducts.map(p => {
            return {
                id: p.id,
                name: p.name,
                currencyCode: p.currencyCode,
                unitPrice: p.price,
                quantity: 1,
                discountPct: 0,
                discountAmt: 0,
                upliftPct: 0,
                upliftAmt: 0,
                finalUnitPrice: p.price,
                totalPrice: p.price,
                gstPct: 0,
                gstAmt: 0,
                totalLineAmount: p.price
            };
        });

        this.isStepOne = false;
        this.isStep3 = true;
    }

    // Reactive Math Engine
    handlePricingChange(event) {
        const prodId = event.target.dataset.id;
        const field = event.target.dataset.field;
        let val = parseFloat(event.target.value);
        if (isNaN(val) || val < 0) val = 0;

        const rows = [...this.step3Data];
        const row = rows.find(r => r.id === prodId);

        if (row) {
            row[field] = val;

            // Math Rules
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
            quoteId: this.recordId,
            productId: p.id,
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

        try {
            await createQuoteLineItems({ lineItems: payload });
            this.showToast('Success', 'Quote Line Items created successfully.', 'success');
            this.handleClose();
        } catch (error) {
            console.error('Error creating records', error);
            this.showToast('Error', 'Failed to create Quote Line Items.', 'error');
            this.isLoading = false;
            this.isCreating = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}