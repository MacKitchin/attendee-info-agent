/**
 * @description Unit tests for CreateFollowUpTask
 */
@IsTest
private class CreateFollowUpTaskTest {
  @TestSetup
  static void setup() {
    Id stdPbId = Test.getStandardPricebookId();

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
  }

  private static Opportunity getTestOpportunity() {
    return [
      SELECT Id, Name
      FROM Opportunity
      WHERE Name = 'Test Opp'
      LIMIT 1
    ];
  }

  /**
   * @description Creates Task with correct WhatId, OwnerId, ActivityDate, Subject, Description
   * Uses running user's email to verify owner matching works
   */
  @IsTest
  static void testCreatesTaskWithCorrectFields() {
    Opportunity opp = getTestOpportunity();

    CreateFollowUpTask.FollowUpTaskInput input = new CreateFollowUpTask.FollowUpTaskInput();
    input.opportunityId = opp.Id;
    input.opportunityName = 'Test Opp';
    input.aiSummary = 'AI analysis: 2 of 3 attendees failed assignment due to missing slots.';

    Test.startTest();
    List<CreateFollowUpTask.FollowUpTaskOutput> results = CreateFollowUpTask.createFollowUpTask(
      new List<CreateFollowUpTask.FollowUpTaskInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(1, results.size(), 'Expected one result');
    System.assertEquals(true, results[0].success, 'Should succeed');
    System.assertNotEquals(null, results[0].taskId, 'Should return a task ID');

    Task createdTask = [
      SELECT Id, WhatId, OwnerId, ActivityDate, Subject, Description, Status, Priority, Type
      FROM Task
      WHERE Id = :results[0].taskId
    ];

    System.assertEquals(opp.Id, createdTask.WhatId, 'WhatId should be the opportunity');
    System.assertEquals(
      UserInfo.getUserId(),
      createdTask.OwnerId,
      'OwnerId should be assigned (running user in test org)'
    );
    System.assertEquals(
      Date.today().addDays(30),
      createdTask.ActivityDate,
      'ActivityDate should be today + 30'
    );
    System.assertEquals(
      'Review Attendee Assignment Failures \u2014 Test Opp',
      createdTask.Subject,
      'Subject should contain em dash and opportunity name'
    );
    System.assertEquals(
      'AI analysis: 2 of 3 attendees failed assignment due to missing slots.',
      createdTask.Description,
      'Description should be the aiSummary'
    );
    System.assertEquals('Not Started', createdTask.Status, 'Status should be Not Started');
    System.assertEquals('Normal', createdTask.Priority, 'Priority should be Normal');
    System.assertEquals('Other', createdTask.Type, 'Type should be Other');
  }

  /**
   * @description Subject truncates opportunityName when > 200 characters
   */
  @IsTest
  static void testSubjectTruncatesLongOpportunityName() {
    Opportunity opp = getTestOpportunity();

    // Build a name longer than 200 characters
    String longName = '';
    for (Integer i = 0; i < 25; i++) {
      longName += 'ABCDEFGHIJ';
    }
    System.assert(longName.length() > 200, 'Name should exceed 200 chars');

    CreateFollowUpTask.FollowUpTaskInput input = new CreateFollowUpTask.FollowUpTaskInput();
    input.opportunityId = opp.Id;
    input.opportunityName = longName;
    input.aiSummary = 'Some summary';

    Test.startTest();
    List<CreateFollowUpTask.FollowUpTaskOutput> results = CreateFollowUpTask.createFollowUpTask(
      new List<CreateFollowUpTask.FollowUpTaskInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success, 'Should succeed');

    Task createdTask = [
      SELECT Subject
      FROM Task
      WHERE Id = :results[0].taskId
    ];

    String expectedSubject = 'Review Attendee Assignment Failures \u2014 ' + longName.left(200);
    System.assertEquals(
      expectedSubject,
      createdTask.Subject,
      'Subject should truncate opportunityName to 200 chars'
    );
  }

  /**
   * @description Falls back to running user when mac.kitchin@informa.com is not found
   * In test org, this email won't exist, so the fallback naturally fires
   */
  @IsTest
  static void testFallsBackToRunningUser() {
    Opportunity opp = getTestOpportunity();

    CreateFollowUpTask.FollowUpTaskInput input = new CreateFollowUpTask.FollowUpTaskInput();
    input.opportunityId = opp.Id;
    input.opportunityName = 'Test Opp';
    input.aiSummary = 'Summary text';

    Test.startTest();
    List<CreateFollowUpTask.FollowUpTaskOutput> results = CreateFollowUpTask.createFollowUpTask(
      new List<CreateFollowUpTask.FollowUpTaskInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success, 'Should succeed');

    Task createdTask = [
      SELECT OwnerId
      FROM Task
      WHERE Id = :results[0].taskId
    ];

    System.assertEquals(
      UserInfo.getUserId(),
      createdTask.OwnerId,
      'OwnerId should fall back to running user when target email not found'
    );
  }

  /**
   * @description Uses fallback description when aiSummary is blank
   */
  @IsTest
  static void testFallbackDescriptionWhenAiSummaryBlank() {
    Opportunity opp = getTestOpportunity();

    CreateFollowUpTask.FollowUpTaskInput input = new CreateFollowUpTask.FollowUpTaskInput();
    input.opportunityId = opp.Id;
    input.opportunityName = 'Test Opp';
    input.aiSummary = '';
    input.statusMessage = 'PARTIAL_ASSIGNED: assigned=2, notAssigned=1';

    Test.startTest();
    List<CreateFollowUpTask.FollowUpTaskOutput> results = CreateFollowUpTask.createFollowUpTask(
      new List<CreateFollowUpTask.FollowUpTaskInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success, 'Should succeed');

    Task createdTask = [
      SELECT Description
      FROM Task
      WHERE Id = :results[0].taskId
    ];

    System.assertEquals(
      'Attendee assignment completed with status: PARTIAL_ASSIGNED: assigned=2, notAssigned=1. AI summary was unavailable.',
      createdTask.Description,
      'Description should use fallback when aiSummary is blank'
    );
  }

  /**
   * @description Uses aiSummary as description when present
   */
  @IsTest
  static void testUsesAiSummaryAsDescription() {
    Opportunity opp = getTestOpportunity();
    String summary = 'AI generated narrative about the assignment failures and recommended actions.';

    CreateFollowUpTask.FollowUpTaskInput input = new CreateFollowUpTask.FollowUpTaskInput();
    input.opportunityId = opp.Id;
    input.opportunityName = 'Test Opp';
    input.aiSummary = summary;
    input.statusMessage = 'PARTIAL_ASSIGNED: assigned=2, notAssigned=1';

    Test.startTest();
    List<CreateFollowUpTask.FollowUpTaskOutput> results = CreateFollowUpTask.createFollowUpTask(
      new List<CreateFollowUpTask.FollowUpTaskInput>{ input }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success, 'Should succeed');

    Task createdTask = [
      SELECT Description
      FROM Task
      WHERE Id = :results[0].taskId
    ];

    System.assertEquals(
      summary,
      createdTask.Description,
      'Description should be the aiSummary when it is present'
    );
  }
}
