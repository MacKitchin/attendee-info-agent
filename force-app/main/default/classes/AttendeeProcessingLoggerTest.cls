/**
 * Test class for AttendeeProcessingLogger, AttendeeAssignmentDetailLogger,
 * and AttendeeProcessingLogUpdater.
 *
 * Required for deployment to production (75% code coverage minimum).
 */
@isTest
private class AttendeeProcessingLoggerTest {
  @TestSetup
  static void setupTestData() {
    // Create a test Account and Opportunity
    Account acc = new Account(Name = 'Test Account');
    insert acc;

    // Use the 'Opportunity' record type which does not require Sales_Territory__c
    Id oppRecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName()
      .get('Opportunity')
      .getRecordTypeId();

    Opportunity opp = new Opportunity(
      Name = 'Test Opportunity',
      AccountId = acc.Id,
      StageName = 'Prospecting/RFP',
      CloseDate = Date.today(),
      RecordTypeId = oppRecordTypeId
    );
    insert opp;
  }

  @isTest
  static void testCreateProcessingLog_Success() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    AttendeeProcessingLogger.ProcessingLogInput input = new AttendeeProcessingLogger.ProcessingLogInput();
    input.opportunityId = opp.Id;
    input.processingType = 'Inbound Reply';
    input.status = 'In Progress';
    input.emailMessageId = '02s000000000001AAA';
    input.outgoingEmailId = '02s000000000002AAA';
    input.senderEmail = 'test@example.com';
    input.senderName = 'Test Sender';
    input.totalRegistrationProducts = 3;
    input.attendeesProvided = 0;
    input.attendeesAssigned = 0;
    input.attendeesNotAssigned = 0;
    input.openSlotsRemaining = 3;
    input.aiModelUsed = 'gpt-4';
    input.errorCategory = 'None';
    input.flowApiName = 'Event_Registration_Process_Attendee_Reply';
    input.flowInterviewGuid = 'test-guid-12345';

    Test.startTest();
    List<AttendeeProcessingLogger.ProcessingLogOutput> outputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(1, outputs.size(), 'Should return one output');
    System.assertEquals(true, outputs[0].success, 'Should succeed');
    System.assertNotEquals(
      null,
      outputs[0].processingLogId,
      'Should return a log ID'
    );
    // Auto-number Name may or may not be returned; verify via SOQL if present
    if (outputs[0].processingLogName != null) {
      System.assert(
        outputs[0].processingLogName.startsWith('APL-'),
        'Name should start with APL-'
      );
    }

    // Verify the record
    Attendee_Processing_Log__c log = [
      SELECT
        Opportunity__c,
        Processing_Type__c,
        Status__c,
        Processing_Date__c,
        Outgoing_Email_Id__c,
        Sender_Email__c,
        Total_Registration_Products__c,
        Flow_API_Name__c
      FROM Attendee_Processing_Log__c
      WHERE Id = :outputs[0].processingLogId
    ];
    System.assertEquals(opp.Id, log.Opportunity__c);
    System.assertEquals('Inbound Reply', log.Processing_Type__c);
    System.assertEquals('In Progress', log.Status__c);
    System.assertNotEquals(null, log.Processing_Date__c);
    System.assertEquals('02s000000000002AAA', log.Outgoing_Email_Id__c);
    System.assertEquals('test@example.com', log.Sender_Email__c);
    System.assertEquals(3, log.Total_Registration_Products__c);
  }

  @isTest
  static void testCreateProcessingLog_DefaultValues() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    AttendeeProcessingLogger.ProcessingLogInput input = new AttendeeProcessingLogger.ProcessingLogInput();
    input.opportunityId = opp.Id;
    // Leave status and errorCategory null to test defaults

    Test.startTest();
    List<AttendeeProcessingLogger.ProcessingLogOutput> outputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ input }
    );
    Test.stopTest();

    Attendee_Processing_Log__c log = [
      SELECT Status__c, Error_Category__c
      FROM Attendee_Processing_Log__c
      WHERE Id = :outputs[0].processingLogId
    ];
    System.assertEquals(
      'In Progress',
      log.Status__c,
      'Default status should be In Progress'
    );
    System.assertEquals(
      'None',
      log.Error_Category__c,
      'Default error category should be None'
    );
  }

  @isTest
  static void testLogAssignmentDetail_Success() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    // First create a processing log
    AttendeeProcessingLogger.ProcessingLogInput logInput = new AttendeeProcessingLogger.ProcessingLogInput();
    logInput.opportunityId = opp.Id;
    logInput.processingType = 'Inbound Reply';
    List<AttendeeProcessingLogger.ProcessingLogOutput> logOutputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ logInput }
    );

    // Now create an assignment detail
    AttendeeAssignmentDetailLogger.AssignmentDetailInput input = new AttendeeAssignmentDetailLogger.AssignmentDetailInput();
    input.processingLogId = logOutputs[0].processingLogId;
    input.productName = 'Appointment Taker - Event ABC';
    input.productType = 'Appointment Taker';
    input.eventName = 'Event ABC';
    input.extractedName = 'John Smith';
    input.extractedEmail = 'john@example.com';
    input.extractedPhone = '555-1234';
    input.assignmentStatus = 'Assigned';
    input.previousAttendeeName = 'Jane Doe';
    input.previousAttendeeEmail = 'jane@example.com';

    Test.startTest();
    List<AttendeeAssignmentDetailLogger.AssignmentDetailOutput> outputs = AttendeeAssignmentDetailLogger.logAssignmentDetail(
      new List<AttendeeAssignmentDetailLogger.AssignmentDetailInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, outputs[0].success);
    System.assertNotEquals(null, outputs[0].assignmentDetailId);
    // Auto-number Name may or may not be returned; verify via SOQL if present
    if (outputs[0].assignmentDetailName != null) {
      System.assert(
        outputs[0].assignmentDetailName.startsWith('AAD-'),
        'Name should start with AAD-'
      );
    }

    Attendee_Assignment_Detail__c detail = [
      SELECT
        Product_Name__c,
        Extracted_Name__c,
        Assignment_Status__c,
        Previous_Attendee_Name__c
      FROM Attendee_Assignment_Detail__c
      WHERE Id = :outputs[0].assignmentDetailId
    ];
    System.assertEquals(
      'Appointment Taker - Event ABC',
      detail.Product_Name__c
    );
    System.assertEquals('John Smith', detail.Extracted_Name__c);
    System.assertEquals('Assigned', detail.Assignment_Status__c);
    System.assertEquals('Jane Doe', detail.Previous_Attendee_Name__c);
  }

  @isTest
  static void testLogAssignmentDetail_Failed() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    AttendeeProcessingLogger.ProcessingLogInput logInput = new AttendeeProcessingLogger.ProcessingLogInput();
    logInput.opportunityId = opp.Id;
    List<AttendeeProcessingLogger.ProcessingLogOutput> logOutputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ logInput }
    );

    AttendeeAssignmentDetailLogger.AssignmentDetailInput input = new AttendeeAssignmentDetailLogger.AssignmentDetailInput();
    input.processingLogId = logOutputs[0].processingLogId;
    input.productName = 'Appointment Taker - Event XYZ';
    input.productType = 'Appointment Taker';
    input.extractedName = 'Bob Wilson';
    input.assignmentStatus = 'Failed';
    input.assignmentError = 'FIELD_CUSTOM_VALIDATION_EXCEPTION: Guaranteed Appointments required';

    Test.startTest();
    List<AttendeeAssignmentDetailLogger.AssignmentDetailOutput> outputs = AttendeeAssignmentDetailLogger.logAssignmentDetail(
      new List<AttendeeAssignmentDetailLogger.AssignmentDetailInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, outputs[0].success);
    Attendee_Assignment_Detail__c detail = [
      SELECT Assignment_Status__c, Assignment_Error__c
      FROM Attendee_Assignment_Detail__c
      WHERE Id = :outputs[0].assignmentDetailId
    ];
    System.assertEquals('Failed', detail.Assignment_Status__c);
    System.assert(
      detail.Assignment_Error__c.contains('Guaranteed Appointments')
    );
  }

  @isTest
  static void testUpdateProcessingLog_Success() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    // Create log
    AttendeeProcessingLogger.ProcessingLogInput logInput = new AttendeeProcessingLogger.ProcessingLogInput();
    logInput.opportunityId = opp.Id;
    logInput.status = 'In Progress';
    List<AttendeeProcessingLogger.ProcessingLogOutput> logOutputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ logInput }
    );

    // Update it
    AttendeeProcessingLogUpdater.UpdateLogInput updateInput = new AttendeeProcessingLogUpdater.UpdateLogInput();
    updateInput.processingLogId = logOutputs[0].processingLogId;
    updateInput.status = 'Partial Success';
    updateInput.attendeesProvided = 3;
    updateInput.attendeesAssigned = 2;
    updateInput.attendeesNotAssigned = 1;
    updateInput.openSlotsRemaining = 1;
    updateInput.aiRawResponse = '{"attendees": [{"name": "John"}]}';
    updateInput.aiModelUsed = 'gpt-4';

    Test.startTest();
    List<AttendeeProcessingLogUpdater.UpdateLogOutput> outputs = AttendeeProcessingLogUpdater.updateProcessingLog(
      new List<AttendeeProcessingLogUpdater.UpdateLogInput>{ updateInput }
    );
    Test.stopTest();

    System.assertEquals(true, outputs[0].success);

    Attendee_Processing_Log__c log = [
      SELECT
        Status__c,
        Attendees_Provided__c,
        Attendees_Assigned__c,
        AI_Model_Used__c
      FROM Attendee_Processing_Log__c
      WHERE Id = :logOutputs[0].processingLogId
    ];
    System.assertEquals('Partial Success', log.Status__c);
    System.assertEquals(3, log.Attendees_Provided__c);
    System.assertEquals(2, log.Attendees_Assigned__c);
    System.assertEquals('gpt-4', log.AI_Model_Used__c);
  }

  @isTest
  static void testCreateProcessingLog_ManualReprocess() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    AttendeeProcessingLogger.ProcessingLogInput input = new AttendeeProcessingLogger.ProcessingLogInput();
    input.opportunityId = opp.Id;
    input.processingType = 'Manual Reprocess';
    input.status = 'Success';

    Test.startTest();
    List<AttendeeProcessingLogger.ProcessingLogOutput> outputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, outputs[0].success);

    Attendee_Processing_Log__c log = [
      SELECT Processing_Type__c, Status__c
      FROM Attendee_Processing_Log__c
      WHERE Id = :outputs[0].processingLogId
    ];
    System.assertEquals('Manual Reprocess', log.Processing_Type__c);
    System.assertEquals('Success', log.Status__c);
  }

  @isTest
  static void testUpdateProcessingLog_ErrorScenario() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

    AttendeeProcessingLogger.ProcessingLogInput logInput = new AttendeeProcessingLogger.ProcessingLogInput();
    logInput.opportunityId = opp.Id;
    List<AttendeeProcessingLogger.ProcessingLogOutput> logOutputs = AttendeeProcessingLogger.createProcessingLog(
      new List<AttendeeProcessingLogger.ProcessingLogInput>{ logInput }
    );

    AttendeeProcessingLogUpdater.UpdateLogInput updateInput = new AttendeeProcessingLogUpdater.UpdateLogInput();
    updateInput.processingLogId = logOutputs[0].processingLogId;
    updateInput.status = 'Failed';
    updateInput.errorMessage = 'AI returned invalid JSON: "I cannot parse this email"';
    updateInput.errorCategory = 'JSON Parse';

    Test.startTest();
    List<AttendeeProcessingLogUpdater.UpdateLogOutput> outputs = AttendeeProcessingLogUpdater.updateProcessingLog(
      new List<AttendeeProcessingLogUpdater.UpdateLogInput>{ updateInput }
    );
    Test.stopTest();

    Attendee_Processing_Log__c log = [
      SELECT Status__c, Error_Message__c, Error_Category__c
      FROM Attendee_Processing_Log__c
      WHERE Id = :logOutputs[0].processingLogId
    ];
    System.assertEquals('Failed', log.Status__c);
    System.assertEquals('JSON Parse', log.Error_Category__c);
    System.assert(log.Error_Message__c.contains('invalid JSON'));
  }
}
