// File: QuotePdfController.cls
public with sharing class QuotePdfController {
    
    public transient Quote__c quote { get; private set; }
    public transient List<LineItemWrapper> lineItems { get; private set; }
    
    // Company Information Properties
    public String companyName { get; private set; }
    public String companyAddress { get; private set; }
    public String companyPhone { get; private set; }
    public String companyFax { get; private set; }

    // Formatted Quote Addresses
    public String formattedBillTo { get; private set; }
    public String formattedShipTo { get; private set; }
    
    // Formatted String Properties for Totals (Direct from Quote__c)
    public String formattedSubtotal { get { return formatCurrency(quote?.Subtotal__c); } }
    public String formattedDiscount {
        get {
            if (quote == null || quote.Discount__c == null) {
                return '0%';
            }
            return quote.Discount__c.setScale(2) + '%';
        }
    }
    public String formattedTotalPrice { get { return formatCurrency(quote?.Total_Price__c); } }
    public String formattedTax { get { return formatCurrency(quote?.Tax__c); } }
    public String formattedShipping { get { return formatCurrency(quote?.Shipping_and_Handling__c); } }
    public String formattedGrandTotal { get { return formatCurrency(quote?.Grand_Total__c); } }

    private ApexPages.StandardController stdController;

    public QuotePdfController(ApexPages.StandardController stdController) {
        this.stdController = stdController;
        Id quoteId = stdController.getId();
        if (String.isNotBlank(quoteId)) {
            loadCompanyInfo();
            loadQuoteData(quoteId);
        }
    }

    /**
     * @description Generates the PDF, saves it as a File, and links it to Quote & Quote_Document__c
     */
    public PageReference savePdf() {
        if (quote == null || quote.Id == null) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No Quote ID found.'));
            return null;
        }

        try {
            // 1. Generate the PDF Blob
            PageReference pdfPage = Page.QuotePDFGenerator;
            pdfPage.getParameters().put('id', quote.Id);
            
            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Test PDF Content');
            } else {
                pdfBlob = pdfPage.getContentAsPDF();
            }

            // 2. Create the Custom Object Record (Metadata)
            Quote_Document__c qDoc = new Quote_Document__c(
                Quote__c         = quote.Id,
                Document_Name__c = quote.Name + ' - ' + System.now().format()
            );
            insert qDoc;

            // 3. Create the ContentVersion (The actual File)
            ContentVersion cv = new ContentVersion(
                Title          = qDoc.Document_Name__c,
                PathOnClient   = qDoc.Document_Name__c + '.pdf',
                VersionData    = pdfBlob,
                IsMajorVersion = true
            );
            insert cv;

            // 4. Get the ContentDocumentId
            Id conDocId = [
                SELECT ContentDocumentId 
                FROM ContentVersion 
                WHERE Id = :cv.Id 
                LIMIT 1
            ].ContentDocumentId;
            
            // 5. Link the File to both the Quote_Document__c and the Quote
            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>{
                new ContentDocumentLink(
                    ContentDocumentId = conDocId,
                    LinkedEntityId    = qDoc.Id,
                    ShareType         = 'V'
                ),
                new ContentDocumentLink(
                    ContentDocumentId = conDocId,
                    LinkedEntityId    = quote.Id,
                    ShareType         = 'V'
                )
            };
            insert linksToInsert;

            // 6. Redirect back to the Quote record (closes the modal)
            PageReference ref = new PageReference('/' + quote.Id);
            ref.setRedirect(true);
            return ref;
            
        } catch (Exception e) {
            ApexPages.addMessages(e);
            return null;
        }
    }

    private void loadCompanyInfo() {
        Organization org = [
            SELECT Name, Street, City, State, PostalCode, Country, Phone, Fax 
            FROM Organization 
            LIMIT 1
        ];
        
        if (String.isNotBlank(org.Street) || String.isNotBlank(org.City) || String.isNotBlank(org.State)) {
            companyName    = org.Name;
            companyAddress = formatAddress(org.Street, org.City, org.State, org.PostalCode, org.Country);
            companyPhone   = org.Phone;
            companyFax     = org.Fax;
        } else {
            try {
                SObject customComp = Database.query(
                    'SELECT Name, Street__c, City__c, State__c, PostalCode__c, Country__c, Phone__c, Fax__c ' +
                    'FROM Company_Information__c LIMIT 1'
                );
                companyName    = (String) customComp.get('Name');
                companyAddress = formatAddress(
                    (String) customComp.get('Street__c'),
                    (String) customComp.get('City__c'),
                    (String) customComp.get('State__c'),
                    (String) customComp.get('PostalCode__c'),
                    (String) customComp.get('Country__c')
                );
                companyPhone = (String) customComp.get('Phone__c');
                companyFax   = (String) customComp.get('Fax__c');
            } catch (Exception e) {
                companyName    = org.Name;
                companyAddress = '';
            }
        }
    }

    private void loadQuoteData(Id quoteId) {
        quote = [
            SELECT Id, Name, CreatedDate, Expiration_Date__c, 
                   CreatedBy.Name, CreatedBy.Email, Contact_Name__c, Phone__c, Fax__c,
                   Bill_To_Name__c, Bill_To__Street__s, Bill_To__City__s, 
                   Bill_To__StateCode__s, Bill_To__PostalCode__s, Bill_To__CountryCode__s,
                   Ship_To_Name__c, Ship_To__Street__s, Ship_To__City__s, 
                   Ship_To__StateCode__s, Ship_To__PostalCode__s, Ship_To__CountryCode__s,
                   Subtotal__c, Discount__c, Total_Price__c, Tax__c, 
                   Shipping_and_Handling__c, Grand_Total__c
            FROM Quote__c 
            WHERE Id = :quoteId 
            LIMIT 1
        ];
                 
        formattedBillTo = formatAddress(
            quote.Bill_To__Street__s, quote.Bill_To__City__s,
            quote.Bill_To__StateCode__s, quote.Bill_To__PostalCode__s, quote.Bill_To__CountryCode__s
        );
        formattedShipTo = formatAddress(
            quote.Ship_To__Street__s, quote.Ship_To__City__s,
            quote.Ship_To__StateCode__s, quote.Ship_To__PostalCode__s, quote.Ship_To__CountryCode__s
        );

        List<Quote_Line_Item__c> qlis = [
            SELECT Id, Product__r.Name, List_Price__c, Sales_Price__c, 
                   Quantity__c, Discount_Percent__c, Total_Price__c
            FROM Quote_Line_Item__c 
            WHERE Quote__c = :quoteId 
            ORDER BY Product__r.Name
        ];
                                         
        lineItems = new List<LineItemWrapper>();
        for (Quote_Line_Item__c qli : qlis) {
            lineItems.add(new LineItemWrapper(qli, this));
        }
    }
    
        @AuraEnabled
    public static void savePdfFromLwc(Id quoteId) {
        Quote__c quote = [SELECT Id, Name FROM Quote__c WHERE Id = :quoteId LIMIT 1];
    
        try {
            PageReference pdfPage = Page.QuotePDFGenerator;
            pdfPage.getParameters().put('id', quoteId);
    
            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Test PDF Content');
            } else {
                pdfBlob = pdfPage.getContentAsPDF();
            }
    
            Quote_Document__c qDoc = new Quote_Document__c(
                Quote__c         = quoteId,
                Document_Name__c = quote.Name + ' - ' + System.now().format()
            );
            insert qDoc;
    
            ContentVersion cv = new ContentVersion(
                Title          = qDoc.Document_Name__c,
                PathOnClient   = qDoc.Document_Name__c + '.pdf',
                VersionData    = pdfBlob,
                IsMajorVersion = true
            );
            insert cv;
    
            Id conDocId = [
                SELECT ContentDocumentId 
                FROM ContentVersion 
                WHERE Id = :cv.Id 
                LIMIT 1
            ].ContentDocumentId;
    
            insert new List<ContentDocumentLink>{
                new ContentDocumentLink(
                    ContentDocumentId = conDocId,
                    LinkedEntityId    = qDoc.Id,
                    ShareType         = 'V'
                ),
                new ContentDocumentLink(
                    ContentDocumentId = conDocId,
                    LinkedEntityId    = quoteId,
                    ShareType         = 'V'
                )
            };
    
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private String formatAddress(String street, String city, String state, String zip, String country) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(street)) parts.add(street);
        String cityStateZip = '';
        if (String.isNotBlank(city))  cityStateZip += city;
        if (String.isNotBlank(state)) cityStateZip += (String.isNotBlank(cityStateZip) ? ', ' : '') + state;
        if (String.isNotBlank(zip))   cityStateZip += ' ' + zip;
        if (String.isNotBlank(cityStateZip)) parts.add(cityStateZip.trim());
        if (String.isNotBlank(country)) parts.add(country);
        return parts.isEmpty() ? '' : String.join(parts, '<br/>');
    }

    public String formatCurrency(Decimal val) {
        if (val == null) val = 0.00;
        val = val.setScale(2);
        String strVal = val.format();
        if (!strVal.contains('.'))                              strVal += '.00';
        else if (strVal.substringAfterLast('.').length() == 1) strVal += '0';
        return UserInfo.getDefaultCurrency() + ' ' + strVal;
    }

    public String formatPercent(Decimal val) {
        if (val == null) return '0.00%';
        return val.setScale(2).format() + '%';
    }

    public class LineItemWrapper {
        public String  productName     { get; private set; }
        public String  listPrice       { get; private set; }
        public String  salesPrice      { get; private set; }
        public Decimal quantity        { get; private set; }
        public String  discountPercent { get; private set; }
        public String  totalPrice      { get; private set; }

        public LineItemWrapper(Quote_Line_Item__c qli, QuotePdfController parent) {
            this.productName     = qli.Product__r != null ? qli.Product__r.Name : 'Unknown Product';
            this.listPrice       = parent.formatCurrency(qli.List_Price__c);
            this.salesPrice      = parent.formatCurrency(qli.Sales_Price__c);
            this.quantity        = qli.Quantity__c != null ? qli.Quantity__c : 0;
            this.discountPercent = parent.formatPercent(qli.Discount_Percent__c);
            this.totalPrice      = parent.formatCurrency(qli.Total_Price__c);
        }
    }
}