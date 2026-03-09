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

    // Contacts that match the attendeesJson() helper emails, on the same Account
    Contact con0 = new Contact(
      FirstName = 'First0',
      LastName = 'Last0',
      Email = 'first0.last0@example.com',
      AccountId = acc.Id
    );
    Contact con1 = new Contact(
      FirstName = 'First1',
      LastName = 'Last1',
      Email = 'first1.last1@example.com',
      AccountId = acc.Id
    );
    insert new List<Contact>{ con0, con1 };

    // Two OLI slots: both initially empty (Attendee fields null)
    OpportunityLineItem oli1 = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 10,
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA'
    );
    insert oli1;

    // Ensure CreatedDate order difference
    Test.setCreatedDate(oli1.Id, System.now().addSeconds(-5));

    OpportunityLineItem oli2 = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 10,
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA'
    );
    insert oli2;
  }

  /**
   * @description Queries the test Opportunity created by @TestSetup
   */
  private static Opportunity getTestOpportunity() {
    return [
      SELECT Id, AccountId
      FROM Opportunity
      WHERE Name = 'Test Opp'
      LIMIT 1
    ];
  }

  /**
   * @description Queries the PricebookEntry created by @TestSetup
   */
  private static PricebookEntry getTestPricebookEntry() {
    return [
      SELECT Id
      FROM PricebookEntry
      WHERE
        Product2.Name = 'Appointment Taker'
        AND Pricebook2Id = :Test.getStandardPricebookId()
      LIMIT 1
    ];
  }

  /**
   * @description Queries the standard Pricebook
   */
  private static Id getStandardPricebookId() {
    return Test.getStandardPricebookId();
  }

  /**
   * @description Generates a JSON string with the given number of test attendees (no event context)
   */
  private static String attendeesJson(Integer count) {
    List<Map<String, Object>> items = new List<Map<String, Object>>();
    for (Integer i = 0; i < count; i++) {
      items.add(
        new Map<String, Object>{
          'first_name' => 'First' + i,
          'last_name' => 'Last' + i,
          'email' => 'first' +
          i +
          '.last' +
          i +
          '@example.com'
        }
      );
    }
    return JSON.serialize(items);
  }

  /**
   * @description Generates a JSON string for a single attendee with event context
   */
  private static String attendeeJson(
    String firstName,
    String lastName,
    String email,
    String eventName,
    String productType
  ) {
    return JSON.serialize(
      new List<Map<String, Object>>{
        new Map<String, Object>{
          'first_name' => firstName,
          'last_name' => lastName,
          'email' => email,
          'event_name' => eventName,
          'product_type' => productType
        }
      }
    );
  }

  /**
   * @description Verifies buildGroupKey normalises case and handles nulls
   */
  @IsTest
  static void testBuildGroupKey() {
    System.assertEquals(
      'mega|corporate',
      ProcessAppointmentTakerAttendees.buildGroupKey('MEGA', 'Corporate')
    );
    System.assertEquals(
      '|',
      ProcessAppointmentTakerAttendees.buildGroupKey(null, null)
    );
    System.assertEquals(
      'spring marketplace|association',
      ProcessAppointmentTakerAttendees.buildGroupKey(
        'Spring Marketplace',
        'Association'
      )
    );
  }

  @IsTest
  static void testHappyPath_exactFill() {
    Opportunity opp = getTestOpportunity();
    AttendeeProcessingLogger.ProcessingLogInput logInput = new AttendeeProcessingLogger.ProcessingLogInput();
    logInput.opportunityId = opp.Id;
    logInput.processingType = 'Inbound Reply';
    List<AttendeeProcessingLogger.ProcessingLogOutput> logOutputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ logInput }
    );

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = attendeesJson(2);
    r.processingLogId = logOutputs[0].processingLogId;

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size(), 'One result expected');
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Should succeed: ' + res[0].statusMessage
    );
    System.assertEquals(2, res[0].attendeesProvided);
    System.assertEquals(2, res[0].attendeesAssigned);
    System.assertEquals(0, res[0].attendeesNotAssigned);
    System.assertEquals(0, res[0].openSlotsRemaining);
    System.assertEquals('Success', res[0].finalStatus);
    System.assertEquals('None', res[0].errorCategory);
    System.assert(
      res[0].statusMessage.contains('SUCCESS_ASSIGNED'),
      'Expected SUCCESS_ASSIGNED in message: ' + res[0].statusMessage
    );

    // Verify OLIs updated
    List<OpportunityLineItem> olis = [
      SELECT
        Id,
        Attendee_First_Name__c,
        Attendee_Name__c,
        Attendee_Email__c,
        Event_Attendee_Contact__c,
        CreatedDate,
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

    // Verify Event Attendee lookup populated from matching Contacts
    List<Contact> testContacts = [
      SELECT Id, Email
      FROM Contact
      WHERE AccountId = :opp.AccountId
      ORDER BY Email
    ];
    Map<String, Id> emailToContact = new Map<String, Id>();
    for (Contact c : testContacts) {
      emailToContact.put(c.Email.toLowerCase(), c.Id);
    }
    System.assertEquals(
      emailToContact.get('first0.last0@example.com'),
      olis[0].Event_Attendee_Contact__c,
      'OLI 0 Event_Attendee_Contact__c should match Contact with first0.last0@example.com'
    );
    System.assertEquals(
      emailToContact.get('first1.last1@example.com'),
      olis[1].Event_Attendee_Contact__c,
      'OLI 1 Event_Attendee_Contact__c should match Contact with first1.last1@example.com'
    );

    List<Attendee_Assignment_Detail__c> details = [
      SELECT Processing_Log__c, Assignment_Status__c, Extracted_Email__c
      FROM Attendee_Assignment_Detail__c
      WHERE Processing_Log__c = :logOutputs[0].processingLogId
      ORDER BY Extracted_Email__c
    ];
    System.assertEquals(
      2,
      details.size(),
      'Two assignment detail logs expected'
    );
    System.assertEquals('Assigned', details[0].Assignment_Status__c);
    System.assertEquals('Assigned', details[1].Assignment_Status__c);
  }

  @IsTest
  static void testMoreAttendeesThanSlots_partialAssigned() {
    Opportunity opp = getTestOpportunity();

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = attendeesJson(3);

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Should succeed with partial assignment: ' + res[0].statusMessage
    );
    System.assert(
      res[0].statusMessage.contains('PARTIAL_ASSIGNED') ||
      res[0].statusMessage.contains('SUCCESS_ASSIGNED'),
      'Expected PARTIAL_ASSIGNED or SUCCESS_ASSIGNED'
    );
    System.assertEquals(3, res[0].attendeesProvided);
    System.assertEquals(2, res[0].attendeesAssigned);
    System.assertEquals(1, res[0].attendeesNotAssigned);
    System.assertEquals(0, res[0].openSlotsRemaining);
    System.assertEquals('Partial Success', res[0].finalStatus);
    System.assert(
      res[0].statusMessage.contains('notAssigned=') &&
      res[0].statusMessage.contains('assigned='),
      'Message should include counts'
    );
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
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA'
    );
    insert oli3;

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = attendeesJson(1);

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Should succeed: ' + res[0].statusMessage
    );
    System.assert(
      res[0].statusMessage.contains('SUCCESS_ASSIGNED') ||
      res[0].statusMessage.contains('PARTIAL_ASSIGNED'),
      'Expected success message: ' + res[0].statusMessage
    );
  }

  @IsTest
  static void testInvalidJson_failure() {
    Opportunity opp = getTestOpportunity();

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = '{invalid json]';

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      false,
      res[0].isSuccess,
      'Should fail for invalid JSON'
    );
    System.assert(
      res[0].statusMessage.contains('INVALID_JSON'),
      'Expected INVALID_JSON marker'
    );
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
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA',
      Attendee_First_Name__c = 'Already',
      Attendee_Name__c = 'Already Filled',
      Attendee_Email__c = 'taken@example.com'
    );
    insert oli;

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp2.Id;
    r.jsonString = attendeesJson(1);

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      true,
      res[0].isSuccess,
      'No open slots should be a success with message'
    );
    System.assert(
      res[0].statusMessage.contains('NO_MATCHING_LINE_ITEMS'),
      'Expected NO_MATCHING_LINE_ITEMS indicator'
    );
  }

  @IsTest
  static void testPartiallyFilledLineItem_notTreatedAsOpen() {
    Id stdPbId = getStandardPricebookId();
    PricebookEntry pbe = getTestPricebookEntry();

    Account acc = new Account(Name = 'Partial Slot Co');
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'Opp Partial Slot',
      StageName = 'Prospecting',
      CloseDate = System.today().addDays(5),
      AccountId = acc.Id,
      Pricebook2Id = stdPbId,
      RecordTypeId = '01230000000bVYmAAM',
      Sales_Territory__c = 'North'
    );
    insert opp;

    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 10,
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA',
      Attendee_Name__c = 'Existing Name'
    );
    insert oli;

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = attendeesJson(1);

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Partially filled slots should not be treated as open'
    );
    System.assert(
      res[0].statusMessage.contains('NO_MATCHING_LINE_ITEMS'),
      'Expected partially filled slot to be excluded from assignment'
    );

    OpportunityLineItem unchanged = [
      SELECT Attendee_Name__c, Attendee_Email__c
      FROM OpportunityLineItem
      WHERE Id = :oli.Id
    ];
    System.assertEquals('Existing Name', unchanged.Attendee_Name__c);
    System.assertEquals(null, unchanged.Attendee_Email__c);
  }

  @IsTest
  static void testEmptyJsonArray_noAttendeesProvided() {
    Opportunity opp = getTestOpportunity();

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = '[]';

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Empty attendees should be no-op success'
    );
    System.assert(
      res[0].statusMessage.contains('NO_ATTENDEES_PROVIDED'),
      'Expected NO_ATTENDEES_PROVIDED marker'
    );
  }

  @IsTest
  static void testMultiEventMatching_correctSlotAssigned() {
    // Set up an Opportunity with two OLIs of DIFFERENT Event Name + Product Type.
    // Each attendee reply carries event context — verify they land on the right OLI.
    Opportunity opp = getTestOpportunity();
    PricebookEntry pbe = getTestPricebookEntry();

    // First OLI: MEGA / Association (the @TestSetup OLIs use BizBash MEGA / Association)
    // Add a second OLI with a DIFFERENT event so we can distinguish them
    OpportunityLineItem oli3 = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 10,
      Guaranteed_Appointments__c = 1,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'North',
      Event_Name__c = 'BizBash North Marketplace'
    );
    insert oli3;

    // Attendee 1 targets North Marketplace / North
    // Attendee 2 targets BizBash MEGA / Association
    String json = JSON.serialize(
      new List<Map<String, Object>>{
        new Map<String, Object>{
          'first_name' => 'NorthFirst',
          'last_name' => 'NorthLast',
          'email' => 'north@example.com',
          'event_name' => 'BizBash North Marketplace',
          'product_type' => 'North'
        },
        new Map<String, Object>{
          'first_name' => 'MegaFirst',
          'last_name' => 'MegaLast',
          'email' => 'mega@example.com',
          'event_name' => 'BizBash MEGA',
          'product_type' => 'Association'
        }
      }
    );

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = json;

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(true, res[0].isSuccess, res[0].statusMessage);

    // Verify correct OLI got the North attendee
    OpportunityLineItem northOli = [
      SELECT Attendee_Email__c
      FROM OpportunityLineItem
      WHERE Id = :oli3.Id
    ];
    System.assertEquals(
      'north@example.com',
      northOli.Attendee_Email__c,
      'BizBash North Marketplace OLI should have north@example.com'
    );

    // Verify one of the BizBash MEGA OLIs got the mega attendee
    List<OpportunityLineItem> megaOlis = [
      SELECT Attendee_Email__c
      FROM OpportunityLineItem
      WHERE
        OpportunityId = :opp.Id
        AND Event_Name__c = 'BizBash MEGA'
        AND Attendee_Email__c != NULL
    ];
    System.assertEquals(
      1,
      megaOlis.size(),
      'One BizBash MEGA OLI should be assigned'
    );
    System.assertEquals('mega@example.com', megaOlis[0].Attendee_Email__c);
  }

  @IsTest
  static void testSameGroupDuplicates_bothAssigned() {
    // Two OLIs with the SAME Event Name + Product Type on the same Opp.
    // Both should get filled, positionally, even though they share a group key.
    Opportunity opp = getTestOpportunity();

    // @TestSetup already created 2 BizBash MEGA / Association OLIs.
    String json = JSON.serialize(
      new List<Map<String, Object>>{
        new Map<String, Object>{
          'first_name' => 'Alice',
          'last_name' => 'Smith',
          'email' => 'alice@example.com',
          'event_name' => 'BizBash MEGA',
          'product_type' => 'Association'
        },
        new Map<String, Object>{
          'first_name' => 'Bob',
          'last_name' => 'Jones',
          'email' => 'bob@example.com',
          'event_name' => 'BizBash MEGA',
          'product_type' => 'Association'
        }
      }
    );

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = json;

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(true, res[0].isSuccess, res[0].statusMessage);
    System.assert(
      res[0].statusMessage.contains('SUCCESS_ASSIGNED'),
      res[0].statusMessage
    );

    List<OpportunityLineItem> filled = [
      SELECT Attendee_Email__c
      FROM OpportunityLineItem
      WHERE OpportunityId = :opp.Id AND Attendee_Email__c != NULL
    ];
    System.assertEquals(2, filled.size(), 'Both slots should be assigned');
  }

  @IsTest
  static void testNonAppointmentTakerProduct_supported() {
    Id stdPbId = getStandardPricebookId();

    Product2 nonAppointmentProduct = new Product2(
      Name = 'Non-Appointment Taker',
      IsActive = true,
      Opportunity_Product_Category__c = 'Event',
      RecordTypeId = '01230000000beHkAAI'
    );
    insert nonAppointmentProduct;

    PricebookEntry nonAppointmentPbe = new PricebookEntry(
      Product2Id = nonAppointmentProduct.Id,
      Pricebook2Id = stdPbId,
      UnitPrice = 10,
      IsActive = true
    );
    insert nonAppointmentPbe;

    Account acc = new Account(Name = 'Non Appointment Account');
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'Opp Non Appointment Product',
      StageName = 'Prospecting',
      CloseDate = System.today().addDays(5),
      AccountId = acc.Id,
      Pricebook2Id = stdPbId,
      RecordTypeId = '01230000000bVYmAAM',
      Sales_Territory__c = 'North'
    );
    insert opp;

    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = nonAppointmentPbe.Id,
      Quantity = 1,
      TotalPrice = 10,
      Organization__c = 'BizBash',
      Product_Year__c = '2026',
      Product_Category__c = 'Event',
      Product_Type__c = 'Association',
      Event_Name__c = 'BizBash MEGA'
    );
    insert oli;

    ProcessAppointmentTakerAttendees.Request r = new ProcessAppointmentTakerAttendees.Request();
    r.opportunityId = opp.Id;
    r.jsonString = attendeesJson(1);

    Test.startTest();
    List<ProcessAppointmentTakerAttendees.Result> res = ProcessAppointmentTakerAttendees.process(
      new List<ProcessAppointmentTakerAttendees.Request>{ r }
    );
    Test.stopTest();

    System.assertEquals(1, res.size());
    System.assertEquals(true, res[0].isSuccess, res[0].statusMessage);

    OpportunityLineItem updated = [
      SELECT Attendee_Name__c, Attendee_Email__c
      FROM OpportunityLineItem
      WHERE Id = :oli.Id
    ];
    System.assertEquals('First0 Last0', updated.Attendee_Name__c);
    System.assertEquals('first0.last0@example.com', updated.Attendee_Email__c);
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
    System.assertEquals(
      true,
      res[0].isSuccess,
      'Blank jsonString considered no-op success'
    );
    System.assertEquals(
      false,
      res[1].isSuccess,
      'Missing opportunityId should be failure'
    );
    System.assertEquals(
      false,
      res[2].isSuccess,
      'Null request should be failure'
    );
  }
}
