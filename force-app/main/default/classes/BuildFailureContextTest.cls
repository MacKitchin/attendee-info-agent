/**
 * @description Unit tests for BuildFailureContext
 */
@IsTest
private class BuildFailureContextTest {
  @TestSetup
  static void setup() {
    Id stdPbId = Test.getStandardPricebookId();

    Product2 prod = new Product2(
      Name = 'Appointment Taker',
      IsActive = true,
      Opportunity_Product_Category__c = 'Event',
      RecordTypeId = '01230000000beHkAAI'
    );
    insert prod;

    PricebookEntry pbe = new PricebookEntry(
      Product2Id = prod.Id,
      Pricebook2Id = stdPbId,
      UnitPrice = 10,
      IsActive = true
    );
    insert pbe;

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

    Attendee_Processing_Log__c log = new Attendee_Processing_Log__c(
      Opportunity__c = opp.Id,
      Processing_Type__c = 'Inbound Reply',
      Status__c = 'Completed',
      Processing_Date__c = System.now()
    );
    insert log;
  }

  private static Opportunity getTestOpportunity() {
    return [
      SELECT Id, Name
      FROM Opportunity
      WHERE Name = 'Test Opp'
      LIMIT 1
    ];
  }

  private static Attendee_Processing_Log__c getTestLog() {
    return [
      SELECT Id
      FROM Attendee_Processing_Log__c
      LIMIT 1
    ];
  }

  /**
   * @description Returns minimal context when processingLogId is null
   */
  @IsTest
  static void testNullProcessingLogId_returnsMinimalContext() {
    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = null;
    req.statusMessage = 'PARTIAL_ASSIGNED: assigned=2, notAssigned=1';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.build(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size(), 'Expected one result');
    String ctx = results[0].formattedContext;
    System.assert(
      ctx.contains('Opportunity: Test Opp'),
      'Should contain opportunity name'
    );
    System.assert(
      ctx.contains('PARTIAL_ASSIGNED'),
      'Should contain status message'
    );
    System.assert(
      ctx.contains(
        'No detailed assignment records are available for this run.'
      ),
      'Should contain no-details message'
    );
  }

  /**
   * @description Returns minimal context when log exists but has no detail records
   */
  @IsTest
  static void testNoDetailRecords_returnsMinimalContext() {
    Attendee_Processing_Log__c log = getTestLog();

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'ERROR: something went wrong';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.build(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size(), 'Expected one result');
    String ctx = results[0].formattedContext;
    System.assert(
      ctx.contains('Opportunity: Test Opp'),
      'Should contain opportunity name'
    );
    System.assert(
      ctx.contains('ERROR: something went wrong'),
      'Should contain status message'
    );
    System.assert(
      ctx.contains(
        'No detailed assignment records are available for this run.'
      ),
      'Should contain no-details message when no detail records exist'
    );
  }

  /**
   * @description Formats correctly with Assigned records only (no failures)
   */
  @IsTest
  static void testAssignedRecordsOnly_formatsCorrectly() {
    Attendee_Processing_Log__c log = getTestLog();

    List<Attendee_Assignment_Detail__c> details = new List<Attendee_Assignment_Detail__c>();
    details.add(
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Assigned',
        Extracted_Name__c = 'Jane Doe',
        Extracted_Email__c = 'jane@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Appointment Taker'
      )
    );
    details.add(
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Assigned',
        Extracted_Name__c = 'Bob Smith',
        Extracted_Email__c = 'bob@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Association'
      )
    );
    insert details;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'SUCCESS_ASSIGNED: assigned=2';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.build(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String ctx = results[0].formattedContext;
    System.assert(
      ctx.contains('Opportunity: Test Opp'),
      'Should contain opportunity name'
    );
    System.assert(
      ctx.contains('ASSIGNED ATTENDEES:'),
      'Should contain assigned section header'
    );
    System.assert(
      ctx.contains('Jane Doe'),
      'Should contain first assigned attendee'
    );
    System.assert(
      ctx.contains('jane@example.com'),
      'Should contain first assigned email'
    );
    System.assert(
      ctx.contains('Bob Smith'),
      'Should contain second assigned attendee'
    );
    System.assert(
      !ctx.contains('FAILED / SKIPPED ATTENDEES:'),
      'Should not contain failed section when no failures exist'
    );
  }

  /**
   * @description Formats correctly with mixed Assigned + Failed + Skipped records
   */
  @IsTest
  static void testMixedStatuses_formatsCorrectly() {
    Attendee_Processing_Log__c log = getTestLog();

    List<Attendee_Assignment_Detail__c> details = new List<Attendee_Assignment_Detail__c>();
    details.add(
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Assigned',
        Extracted_Name__c = 'Jane Doe',
        Extracted_Email__c = 'jane@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Appointment Taker'
      )
    );
    details.add(
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Failed',
        Extracted_Name__c = 'John Smith',
        Extracted_Email__c = 'john@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Non-Appointment Taker',
        Assignment_Error__c = 'No available open registration slot for attendee.'
      )
    );
    details.add(
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Skipped',
        Extracted_Name__c = 'Alice Wonder',
        Extracted_Email__c = 'alice@example.com',
        Event_Name__c = 'BizBash North',
        Product_Type__c = 'Association',
        Assignment_Error__c = 'Duplicate attendee entry.'
      )
    );
    insert details;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'PARTIAL_ASSIGNED: assigned=1, notAssigned=2';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.build(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String ctx = results[0].formattedContext;
    System.assert(
      ctx.contains('Opportunity: Test Opp'),
      'Should contain opportunity name'
    );
    System.assert(
      ctx.contains('Overall Status: PARTIAL_ASSIGNED'),
      'Should contain overall status'
    );
    System.assert(
      ctx.contains('ASSIGNED ATTENDEES:'),
      'Should contain assigned section'
    );
    System.assert(
      ctx.contains('Jane Doe (jane@example.com)'),
      'Should contain assigned attendee with email'
    );
    System.assert(
      ctx.contains('FAILED / SKIPPED ATTENDEES:'),
      'Should contain failed/skipped section'
    );
    System.assert(
      ctx.contains('John Smith (john@example.com)'),
      'Should contain failed attendee'
    );
    System.assert(
      ctx.contains('No available open registration slot for attendee.'),
      'Should contain failure reason'
    );
    System.assert(
      ctx.contains('Alice Wonder (alice@example.com)'),
      'Should contain skipped attendee'
    );
    System.assert(
      ctx.contains('Duplicate attendee entry.'),
      'Should contain skip reason'
    );
  }

  /**
   * @description Truncates output to <= 10,000 chars and appends truncation marker
   */
  @IsTest
  static void testTruncation_outputCappedAt10000Chars() {
    Attendee_Processing_Log__c log = getTestLog();

    // Create enough detail records to exceed 10,000 characters
    List<Attendee_Assignment_Detail__c> details = new List<Attendee_Assignment_Detail__c>();
    for (Integer i = 0; i < 100; i++) {
      details.add(
        new Attendee_Assignment_Detail__c(
          Processing_Log__c = log.Id,
          Assignment_Status__c = 'Failed',
          Extracted_Name__c = 'FailedAttendeeWithAVeryLongNameNumber' + i,
          Extracted_Email__c = 'failed.attendee.with.long.email.' +
            i +
            '@verylongdomainname.example.com',
          Event_Name__c = 'BizBash MEGA International Conference ' + i,
          Product_Type__c = 'Non-Appointment Taker',
          Assignment_Error__c = 'No available open registration slot for this attendee. The slot was already filled by another attendee in a prior processing run. Please contact your administrator for assistance with slot number ' +
            i +
            '.'
        )
      );
    }
    insert details;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'FAILURE: all attendees failed assignment';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.build(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String ctx = results[0].formattedContext;
    System.assert(
      ctx.length() <= 10000,
      'Output should be <= 10,000 chars but was ' + ctx.length()
    );
    System.assert(
      ctx.contains('[truncated'),
      'Should contain truncation marker'
    );
    System.assert(
      ctx.contains('Opportunity: Test Opp'),
      'Header should be preserved after truncation'
    );
    System.assert(
      ctx.contains('FAILED / SKIPPED ATTENDEES:'),
      'Failed section header should be preserved'
    );
  }
}
