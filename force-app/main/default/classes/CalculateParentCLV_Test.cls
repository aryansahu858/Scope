@isTest
public class CalculateParentCLV_Test {

    @isTest
    static void testCalculateCLV() {
        
        Account parentAcc = new Account(
            Name = 'Parenr Account',
            Customer_Lifetime_Value__c = 100
        );
        insert parentAcc;
        
        
        Account childAcc = new Account(
            Name = 'Test Account',
            ParentId  = parentAcc.Id,
            Customer_Lifetime_Value__c = 100
        );
        insert childAcc;
        
        
        
        Opportunity__c opp = new Opportunity__c(
            Name = 'Test Privated limites',
            Account_Name__c  = childAcc.Id,
            Amount__c = 40000
        );
        
        insert opp;

        
        CalculateParentCLV.FlowInput input = new CalculateParentCLV.FlowInput();
        input.accountId = childAcc.Id;
        input.childTotalCLV = 50;

        List<CalculateParentCLV.FlowInput> inputList = new List<CalculateParentCLV.FlowInput>();
        inputList.add(input);

        Test.startTest();
        CalculateParentCLV.flowDataForCLV(inputList);
        Test.stopTest();

        
        Account updatedAcc = [
            SELECT Customer_Lifetime_Value__c
            FROM Account
            WHERE Id = :childAcc.Id
        ];

        System.assertEquals(150, updatedAcc.Customer_Lifetime_Value__c);
    }
}