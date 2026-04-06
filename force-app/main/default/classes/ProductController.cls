/**
 * @description  Apex Controller for Product Related List LWC
 * Provides AuraEnabled methods to fetch Product__c records
 * with optional search/filter support, variant pricing, 
 * and record-level association.
 */
public class ProductController {

    private static final Integer DEFAULT_LIMIT  = 50;
    private static final Integer RELATED_LIMIT  = 5;


    @AuraEnabled(cacheable=true)
    public static List<Product__c> getProducts(String searchTerm, Integer limitSize, Id quoteId) {
        try {
            // Fetch Quote
            List<Quote__c> quotes = [
                SELECT PriceBook__c, Opportunity_Name__c
                FROM Quote__c 
                WHERE Id = :quoteId 
                LIMIT 1
            ];

            if (quotes.isEmpty()) {
                throw new AuraHandledException('Quote not found.');
            }

            Quote__c quoteRec = quotes[0];

            if (quoteRec.PriceBook__c == null) {
                throw new AuraHandledException('No Price Book assigned to this Quote.');
            }

            if (quoteRec.Opportunity_Name__c == null) {
                throw new AuraHandledException('No Opportunity linked to this Quote.');
            }

            // Fetch Opportunity Currency safely
            List<Opportunity__c> oppList = [
                SELECT CurrencyIsoCode 
                FROM Opportunity__c 
                WHERE Id = :quoteRec.Opportunity_Name__c 
                LIMIT 1
            ];

            if (oppList.isEmpty()) {
                throw new AuraHandledException('Opportunity not found.');
            }

            Opportunity__c opp = oppList[0];

            if (String.isBlank(opp.CurrencyIsoCode)) {
                throw new AuraHandledException('Currency is not defined on the Opportunity.');
            }

            String oppCurrency = opp.CurrencyIsoCode;

            Id priceBookId = quoteRec.PriceBook__c;

            Integer queryLimit = (limitSize != null && limitSize > 0) 
                ? limitSize 
                : DEFAULT_LIMIT;

            String searchKey = String.isNotBlank(searchTerm) 
                ? '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%' 
                : '%';

            // Fetch products
            List<Product__c> products = [
                SELECT Id, Name, Product_Code__c, Product_Family__c, Product_Description__c
                FROM Product__c
                WHERE (Name LIKE :searchKey OR Product_Code__c LIKE :searchKey)
                AND Id IN (
                    SELECT Product__c 
                    FROM Price_Book_Entry__c 
                    WHERE Price_Book__c = :priceBookId
                        AND CurrencyIsoCode = :oppCurrency
                        AND List_Price__c != null
                )
                ORDER BY Name ASC
                LIMIT :queryLimit
            ];

            if (products.isEmpty()) {
                throw new AuraHandledException(
                    'No products available for the selected Price Book and Currency.'
                );
            }

            return products;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to fetch products: ' + ex.getMessage());
        }
    }

    // ENHANCEMENT 3: Fetch Existing Data with Variant Configs and Pricing
    @AuraEnabled(cacheable=true)
    public static List<Quote_Line_Item__c> getRelatedQuoteProducts(Id recordId) {
        try {
            return [
                SELECT Id, Product__c, Product__r.Name, Product__r.Product_Family__c,
                       Product_Variant_Master__c,
                       Product_Variant_Master__r.Config_Opt_1__c,
                       Product_Variant_Master__r.Config_Opt_2__c,
                       Product_Variant_Master__r.Config_Opt_3__c,
                       Product_Variant_Master__r.Config_Opt_4__c,
                       Product_Variant_Master__r.Config_Opt_5__c,
                       Product_Variant_Master__r.Config_Opt_6__c,
                       Product_Variant_Master__r.Config_Opt_7__c,
                       Product_Variant_Master__r.Config_Opt_8__c,
                       Product_Variant_Master__r.Config_Opt_9__c,
                       Product_Variant_Master__r.Config_Opt_10__c,
                       List_Price__c, Quantity__c, Discount_Percent__c, Uplift_Percent__c, GST_Percent__c
                FROM Quote_Line_Item__c
                WHERE Quote__c = :recordId
            ];
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to fetch existing quote products: ' + ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Product__c> getRelatedProducts(Id recordId) {
        try {
            return [
                SELECT Id, Name, Product_Code__c, Product_Family__c
                FROM Product__c
                ORDER BY Name ASC
                LIMIT :RELATED_LIMIT
            ];
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to fetch related products: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static List<Product_Variant_Master__c> getVariantData(List<Id> productIds) {
        try {
            return [
                SELECT Id, Product__c, RSP__c, CurrencyIsoCode,
                    Config_Opt_1__c, Config_Opt_2__c, Config_Opt_3__c, Config_Opt_4__c, Config_Opt_5__c,
                    Config_Opt_6__c, Config_Opt_7__c, Config_Opt_8__c, Config_Opt_9__c, Config_Opt_10__c
                FROM Product_Variant_Master__c
                WHERE Product__c IN :productIds
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching variants: ' + e.getMessage());
        }
    }

    public class PricingContext {
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Boolean isValidPriceBook;
        @AuraEnabled public Decimal convertedPrice;
        @AuraEnabled public String errorMessage;
    }

    @AuraEnabled
    public static PricingContext validateAndConvertPrice(Id quoteId, Id productId, Decimal rspValue, String rspCurrency) {
        PricingContext result = new PricingContext();
        try {
            Quote__c q = [SELECT Opportunity_Name__r.CurrencyIsoCode FROM Quote__c WHERE Id = :quoteId LIMIT 1];
            if (q.Opportunity_Name__c == null || q.Opportunity_Name__r.CurrencyIsoCode == null) {
                result.errorMessage = 'No Opportunity or Currency linked to this Quote.';
                return result;
            }
            result.currencyCode = q.Opportunity_Name__r.CurrencyIsoCode;
            
            Integer pbeCount = [
                SELECT COUNT() FROM Price_Book_Entry__c 
                WHERE Product__c = :productId AND CurrencyIsoCode = :result.currencyCode
            ];
            
            result.isValidPriceBook = (pbeCount > 0);
            if (!result.isValidPriceBook) {
                result.errorMessage = 'No Price Book Entry available for selected product in Opportunity currency (' + result.currencyCode + ')';
                return result;
            }
            
            if (rspCurrency != result.currencyCode) {
                Map<String, Decimal> rates = new Map<String, Decimal>();
                for(SObject ct : Database.query('SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsActive = true')) {
                    rates.put((String)ct.get('IsoCode'), (Decimal)ct.get('ConversionRate'));
                }
                Decimal fromRate = rates.get(rspCurrency);
                Decimal toRate = rates.get(result.currencyCode);
                
                if (fromRate != null && toRate != null && fromRate != 0) {
                    result.convertedPrice = (rspValue / fromRate) * toRate;
                } else {
                    result.convertedPrice = rspValue;
                }
            } else {
                result.convertedPrice = rspValue;
            }
        } catch(Exception e) {
            result.errorMessage = 'Pricing Validation Error: ' + e.getMessage();
        }
        return result;
    }

    // ENHANCEMENT 2 & 3: Upsert Logic handling Variant mapping and Existing records
   @AuraEnabled
    public static void upsertQuoteLineItems(List<Map<String, Object>> lineItems) {
        try {
            List<Quote_Line_Item__c> recordsToUpsert = new List<Quote_Line_Item__c>();

            for (Map<String, Object> line : lineItems) {
                Quote_Line_Item__c qli = new Quote_Line_Item__c();

                if (line.get('qliId') != null) {
                    qli.Id = Id.valueOf(String.valueOf(line.get('qliId')));
                }

                
                if (qli.Id == null && line.get('quoteId') != null && String.isNotBlank(String.valueOf(line.get('quoteId')))) {
                    qli.Quote__c = Id.valueOf(String.valueOf(line.get('quoteId')).trim());
                }

                if (line.get('productId') != null && String.isNotBlank(String.valueOf(line.get('productId')))) {
                    qli.Product__c = Id.valueOf(String.valueOf(line.get('productId')).trim());
                }

                if (line.get('variantId') != null && String.isNotBlank(String.valueOf(line.get('variantId')))) {
                    qli.Product_Variant_Master__c = Id.valueOf(String.valueOf(line.get('variantId')).trim());
                }


                qli.List_Price__c = (line.get('unitPrice') != null) ? Decimal.valueOf(String.valueOf(line.get('unitPrice'))) : null;
                qli.Sales_Price__c = (line.get('unitPrice') != null) ? Decimal.valueOf(String.valueOf(line.get('unitPrice'))) : null;
                qli.Quantity__c = (line.get('quantity') != null) ? Decimal.valueOf(String.valueOf(line.get('quantity'))) : null;
                qli.Discount_Percent__c = (line.get('discountPct') != null) ? Decimal.valueOf(String.valueOf(line.get('discountPct'))) : null;
                qli.Uplift_Percent__c = (line.get('upliftPct') != null) ? Decimal.valueOf(String.valueOf(line.get('upliftPct'))) : null;
                qli.GST_Percent__c = (line.get('gstPct') != null) ? Decimal.valueOf(String.valueOf(line.get('gstPct'))) : null;

                recordsToUpsert.add(qli);

            }

            if (!recordsToUpsert.isEmpty()) {
                Database.upsert(recordsToUpsert, false);
            }

        } catch (Exception e) {
            throw new AuraHandledException('Error upserting Quote Line Items: ' + e.getMessage());
        }
    }

}