public class CalculateParentCLV {
    
    
    @InvocableMethod(label='Update ParentCLV Total' description='Updates Customer Individual total in parent account')
    public static void flowDataForCLV(List<FlowInput> inputFromFlow){
        if(inputFromFlow != null){
            for(FlowInput acc : inputFromFlow){
                calculateCLV_Total(acc.accountId , acc.childTotalCLV);
            }
        }
        
    }
    
    public static void calculateCLV_Total(String accountId , Decimal childTotalCLV){
        //Check if there is any parent account there or not 
        List<Account> storeParentAccount = [Select Id , Customer_Lifetime_Value__c,Customer_Lifetime_Value_Individual__c  from Account where Id =: accountId];
        List<Account> storeUpdatedAccount = new List<Account>();
        System.debug('Child Total-CLV-->' + childTotalCLV);
        if(storeParentAccount != null){
            for(Account parAccount : storeParentAccount){
                System.debug('Enter in this Problem' + parAccount.Id + 'CLV' + parAccount.Customer_Lifetime_Value_Individual__c);
                Account acc = new Account();
                acc.Id = parAccount.Id;
                acc.Customer_Lifetime_Value__c  = (parAccount.Customer_Lifetime_Value_Individual__c == null ? 0 : parAccount.Customer_Lifetime_Value_Individual__c) + childTotalCLV;
                System.debug('This is the last value -->' + acc);
                storeUpdatedAccount.add(acc);
                
            }
        }
        System.debug('storeUpdatedAccount' + storeUpdatedAccount);
        if(storeUpdatedAccount != Null){
            UPDATE storeUpdatedAccount;
        }
        
        
    }
    
    public class FlowInput{
        @InvocableVariable(required=true)
        public String accountId;
        @InvocableVariable(required=true)
        public Decimal childTotalCLV;
    }

}