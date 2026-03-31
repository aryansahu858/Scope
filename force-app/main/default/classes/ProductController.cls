/**
 * @description  Apex Controller for Product Related List LWC
 * Provides AuraEnabled methods to fetch Product__c records
 * with optional search/filter support, variant pricing, 
 * and record-level association.
 *
 * @author       Aryan Sahu
 * @version      1.1
 */
public with sharing class ProductController {

    private static final Integer DEFAULT_LIMIT  = 50;
    private static final Integer RELATED_LIMIT  = 5;

    // ENHANCEMENT 1: Filter by Quote's Price Book
    @AuraEnabled(cacheable=true)
    public static List<Product__c> getProducts(String searchTerm, Integer limitSize, Id quoteId) {

         System.debug(searchTerm);
          System.debug(limitSize);
           System.debug(quoteId);

        try {
            
            // 1. Fetch Price Book from Quote
            Quote__c quoteRec = [SELECT PriceBook__c FROM Quote__c WHERE Id = :quoteId LIMIT 1];
            System.debug(quoteRec);
            if (quoteRec.PriceBook__c == null) {
                throw new AuraHandledException('No Price Book assigned to this Quote.');
            }
            Id priceBookId = quoteRec.PriceBook__c;

            System.debug(priceBookId);

            //  return [
            //     SELECT Id, Name, Product_Code__c, Product_Family__c, Product_Description__c
            //     FROM Product__c
            // ];

            Integer queryLimit = (limitSize != null && limitSize > 0) ? limitSize : DEFAULT_LIMIT;
            String searchKey = String.isNotBlank(searchTerm) 
                ? '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%' 
                : '%';

            // // 2. Query Products filtered by Price Book Entry junction
            return [
                SELECT Id, Name, Product_Code__c, Product_Family__c, Product_Description__c
                FROM Product__c
                WHERE (Name LIKE :searchKey OR Product_Code__c LIKE :searchKey)
                  AND Id IN (SELECT Product__c FROM Price_Book_Entry__c WHERE Price_Book__c = :priceBookId)
                ORDER BY Name ASC
                LIMIT :queryLimit
            ];
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to fetch products: ' + ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Quote_Line_Item__c> getRelatedQuoteProducts(Id recordId) {
        try {
            return [
                SELECT Id, Product__r.Name, Product__c, Quantity__c, Sales_Price__c, Product__r.Product_Family__c
                FROM Quote_Line_Item__c
                WHERE Quote__c = :recordId
            ];
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to fetch products: ' + ex.getMessage());
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
    public static void addProductsToRecord(Id recordId, List<Id> productIds) {
        try {
            if (productIds == null || productIds.isEmpty()) {
                throw new AuraHandledException('No products provided.');
            }
            System.debug('Adding products ' + productIds + ' to record ' + recordId);
        } catch (Exception ex) {
            throw new AuraHandledException('Failed to add products: ' + ex.getMessage());
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
                SELECT COUNT() 
                FROM Price_Book_Entry__c 
                WHERE Product__c = :productId 
                AND CurrencyIsoCode = :result.currencyCode
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

    // ENHANCEMENT 4: Payload matches Step 3 matrix
    @AuraEnabled
    public static void createQuoteLineItems(List<Map<String, Object>> lineItems) {
        try {
            List<Quote_Line_Item__c> recordsToInsert = new List<Quote_Line_Item__c>();
            
            for (Map<String, Object> line : lineItems) {
                Quote_Line_Item__c qli = new Quote_Line_Item__c();
                qli.Quote__c = (Id) line.get('quoteId');
                qli.Product__c = (Id) line.get('productId');
                qli.List_Price__c = Decimal.valueOf(String.valueOf(line.get('unitPrice')));
                qli.Quantity__c = Decimal.valueOf(String.valueOf(line.get('quantity')));
                qli.Discount_Percent__c = Decimal.valueOf(String.valueOf(line.get('discountPct')));
                //qli.Discount_Amount__c = Decimal.valueOf(String.valueOf(line.get('discountAmt')));
                qli.Uplift_Percent__c = Decimal.valueOf(String.valueOf(line.get('upliftPct')));
                //qli.Uplift_Amount__c = Decimal.valueOf(String.valueOf(line.get('upliftAmt')));
                //qli.Final_Unit_Price__c = Decimal.valueOf(String.valueOf(line.get('finalUnitPrice')));
                qli.Total_Price__c = Decimal.valueOf(String.valueOf(line.get('totalPrice')));
                qli.GST_Percent__c = Decimal.valueOf(String.valueOf(line.get('gstPct')));
                //qli.GST_Amount__c = Decimal.valueOf(String.valueOf(line.get('gstAmt')));
                //qli.Total_Line_Amount__c = Decimal.valueOf(String.valueOf(line.get('totalLineAmount')));
                recordsToInsert.add(qli);
            }
            
            if (!recordsToInsert.isEmpty()) {
                insert recordsToInsert;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error creating Quote Line Items: ' + e.getMessage());
        }
    }
}