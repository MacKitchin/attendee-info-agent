/**
 * @description Unit tests for ProcessAppointmentTakerAttendees
 */
@IsTest
private class ProcessAppointmentTakerAttendeesTest {

    @TestSetup
    static void setup() {
        // Standard Pricebook — use Test.getStandardPricebookId() since standard PB
        // is not queryable in test context without SeeAllData=true
        Id stdPbId = Test.getStandardPricebookId();

        // Product
        Product2 prod = new Product2(
            Name = 'Appointment Taker',
            IsActive = true,
            Opportunity_Product_Category__c = 'Event',
            RecordTypeId = '01230000000beHkAAI'
        );
        insert prod;

        // PBE
        PricebookEntry pbe = new PricebookEntry(
            Product2Id = prod.Id,
            Pricebook2Id = stdPbId,
            UnitPrice = 10,
            IsActive = true
        );
        insert pbe;

        // Account + Opportunity
        Account acc = new Account(Name = 'Test Acme');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            StageName = 'Prospecting',
            CloseDate = System.today().addDays(10),
            AccountId = acc.Id,
            Pricebook2Id = stdPbId,
            RecordTypeId = '01230000000bVYmAAM',
            Sales_Territory__c = 'North'
        );
        insert opp;

        // Two OLI slots: both initially empty (Attendee fields null)
        OpportunityLineItem oli1 = new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            TotalPrice = 10,
            Organization__c = 'BizBash', Product_Year__c = '2026', Product_Category__c = 'Event', Product_Type__c = 'Association', Event_Name__c = 'BizBash MEGA'
        );
        insert oli1;

        // Ensure CreatedDate order difference
        Test.setCreatedDate(oli1.Id, System.now().addSeconds(-5));

        OpportunityLineItem oli2 = new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            TotalPrice = 10,
            Organization__c = 'BizBash', Product_Year__c = '2026', Product_Category__c = 'Event', Product_Type__c = 'Association', Event_Name__c = 'BizBash MEGA'
        );
        insert oli2;
    }

    /**
     * @description Queries the test Opportunity created by @TestSetup
     */
    private static Opportunity getTestOpportunity() {
        return [SELECT Id FROM Opportunity WHERE Name = 'Test Opp' LIMIT 1];
    }

    /**
     * @description Queries the PricebookEntry created by @TestSetup
     */
    private static PricebookEntry getTestPricebookEntry() {
        return [SELECT Id FROM PricebookEntry WHERE Product2.Name = 'Appointment Taker' AND Pricebook2Id = :Test.getStandardPricebookId() LIMIT 1];
    }

    /**
     * @description Queries the standard Pricebook
     */
    private static Id getStandardPricebookId() {
        return Test.getStandardPricebookId();
    }

    /**
     * @description Generates a JSON string with the given number of test attendees
     */
    private static String attendeesJson(Integer count) {
        List<Map<String, Object>> items = new List<Map<String, Object>>();
        for (Integer i = 0; i < count; i++) {
            items.add(new Map<String, Object>{
                'first_name' => 'First' + i,
                'last_name' => 'Last' + i,
                'email' => 'first' + i + '.last' + i + '@example.com'
            });
        }
        return JSON.serialize(items);
    }

    @IsTest
    static void testHappyPath_exactFill() {
        Opportunity opp = getTestOpportunity();

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp.Id;
        r.jsonString = attendeesJson(2);

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size(), 'One result expected');
        System.assertEquals(true, res[0].isSuccess, 'Should succeed: ' + res[0].statusMessage);
        System.assert(res[0].statusMessage.contains('SUCCESS_ASSIGNED'), 'Expected SUCCESS_ASSIGNED in message: ' + res[0].statusMessage);

        // Verify OLIs updated
        List<OpportunityLineItem> olis = [
            SELECT Id, Attendee_First_Name__c, Attendee_Name__c, Attendee_Email__c, CreatedDate,
                   Product2.Name
            FROM OpportunityLineItem
            WHERE OpportunityId = :opp.Id
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, olis.size(), 'Two OLIs exist');
        System.assertEquals('First0', olis[0].Attendee_First_Name__c);
        System.assertEquals('First0 Last0', olis[0].Attendee_Name__c);
        System.assertEquals('first0.last0@example.com', olis[0].Attendee_Email__c);
        System.assertEquals('First1', olis[1].Attendee_First_Name__c);
        System.assertEquals('First1 Last1', olis[1].Attendee_Name__c);
        System.assertEquals('first1.last1@example.com', olis[1].Attendee_Email__c);
    }

    @IsTest
    static void testMoreAttendeesThanSlots_partialAssigned() {
        Opportunity opp = getTestOpportunity();

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp.Id;
        r.jsonString = attendeesJson(3);

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size());
        System.assertEquals(true, res[0].isSuccess, 'Should succeed with partial assignment: ' + res[0].statusMessage);
        System.assert(res[0].statusMessage.contains('PARTIAL_ASSIGNED') || res[0].statusMessage.contains('SUCCESS_ASSIGNED'),
            'Expected PARTIAL_ASSIGNED or SUCCESS_ASSIGNED');
        System.assert(res[0].statusMessage.contains('notAssigned=') && res[0].statusMessage.contains('assigned='), 'Message should include counts');
    }

    @IsTest
    static void testFewerAttendeesThanSlots_successAssigned() {
        Opportunity opp = getTestOpportunity();
        PricebookEntry pbe = getTestPricebookEntry();

        // Add a third OLI so we have 3 slots total; provide 1 attendee
        OpportunityLineItem oli3 = new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            TotalPrice = 10,
            Organization__c = 'BizBash', Product_Year__c = '2026', Product_Category__c = 'Event', Product_Type__c = 'Association', Event_Name__c = 'BizBash MEGA'
        );
        insert oli3;

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp.Id;
        r.jsonString = attendeesJson(1);

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size());
        System.assertEquals(true, res[0].isSuccess, 'Should succeed: ' + res[0].statusMessage);
        System.assert(res[0].statusMessage.contains('SUCCESS_ASSIGNED') || res[0].statusMessage.contains('PARTIAL_ASSIGNED'),
            'Expected success message: ' + res[0].statusMessage);
    }

    @IsTest
    static void testInvalidJson_failure() {
        Opportunity opp = getTestOpportunity();

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp.Id;
        r.jsonString = '{invalid json]';

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size());
        System.assertEquals(false, res[0].isSuccess, 'Should fail for invalid JSON');
        System.assert(res[0].statusMessage.contains('INVALID_JSON'), 'Expected INVALID_JSON marker');
    }

    @IsTest
    static void testNoMatchingLineItems_successNoSlots() {
        Id stdPbId = getStandardPricebookId();
        PricebookEntry pbe = getTestPricebookEntry();

        // Create a different Opportunity with zero "open" appointment taker OLIs
        Account a2 = new Account(Name = 'No Slots Co');
        insert a2;

        Opportunity opp2 = new Opportunity(
            Name = 'Opp No Slots',
            StageName = 'Prospecting',
            CloseDate = System.today().addDays(5),
            AccountId = a2.Id,
            Pricebook2Id = stdPbId,
            RecordTypeId = '01230000000bVYmAAM',
            Sales_Territory__c = 'North'
        );
        insert opp2;

        // OLI but filled so it is not "open" per predicate
        OpportunityLineItem oli = new OpportunityLineItem(
            OpportunityId = opp2.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            TotalPrice = 10,
            Organization__c = 'BizBash', Product_Year__c = '2026', Product_Category__c = 'Event', Product_Type__c = 'Association', Event_Name__c = 'BizBash MEGA',
            Attendee_First_Name__c = 'Already',
            Attendee_Name__c = 'Already Filled',
            Attendee_Email__c = 'taken@example.com'
        );
        insert oli;

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp2.Id;
        r.jsonString = attendeesJson(1);

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size());
        System.assertEquals(true, res[0].isSuccess, 'No open slots should be a success with message');
        System.assert(res[0].statusMessage.contains('NO_MATCHING_LINE_ITEMS'), 'Expected NO_MATCHING_LINE_ITEMS indicator');
    }

    @IsTest
    static void testEmptyJsonArray_noAttendeesProvided() {
        Opportunity opp = getTestOpportunity();

        ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
        r.opportunityId = opp.Id;
        r.jsonString = '[]';

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(new List<ProcessAppointmentTakerAttendees.Request>{ r });
        Test.stopTest();

        System.assertEquals(1, res.size());
        System.assertEquals(true, res[0].isSuccess, 'Empty attendees should be no-op success');
        System.assert(res[0].statusMessage.contains('NO_ATTENDEES_PROVIDED'), 'Expected NO_ATTENDEES_PROVIDED marker');
    }

    @IsTest
    static void testBlankInputs_andNullRequest() {
        Opportunity opp = getTestOpportunity();

        // Blank jsonString treated as no-op success
        ProcessAppointmentTakerAttendees.Request r1 = new ProcessAppointmentTakerAttendees.Request();
        r1.opportunityId = opp.Id;
        r1.jsonString = '';

        // Missing opportunityId should be error
        ProcessAppointmentTakerAttendees.Request r2 = new ProcessAppointmentTakerAttendees.Request();
        r2.jsonString = attendeesJson(1);
        r2.opportunityId = null;

        Test.startTest();
        List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
            new List<ProcessAppointmentTakerAttendees.Request>{ r1, r2, null }
        );
        Test.stopTest();

        System.assertEquals(3, res.size());
        System.assertEquals(true, res[0].isSuccess, 'Blank jsonString considered no-op success');
        System.assertEquals(false, res[1].isSuccess, 'Missing opportunityId should be failure');
        System.assertEquals(false, res[2].isSuccess, 'Null request should be failure');
    }
}
