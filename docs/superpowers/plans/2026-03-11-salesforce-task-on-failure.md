# Salesforce Task on Attendee Assignment Failure — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When attendee assignment produces a `Partial Success` or `Failed` result, create a Salesforce Task assigned to Mac Kitchin with an AI-generated narrative explaining exactly what happened and why.

**Architecture:** Two new invocable Apex classes (`BuildFailureContext` and `CreateFollowUpTask`) plus a new GenAI prompt template (`Attendee_Assignment_Failure_Summary`). The Flow is modified to add a `Decision_Needs_Task` node on both its success and failure branches (because `Partial Success` and several `Failed` paths exit through `isSuccess = true`), which chains: build context → AI summarize → create Task.

**Tech Stack:** Salesforce Apex, Flow Builder XML, GenAI Prompt Templates (einstein_gpt__flex), Claude 4.5 Haiku via Bedrock

**Spec:** `docs/superpowers/specs/2026-03-11-salesforce-task-on-failure-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `force-app/main/default/classes/BuildFailureContext.cls` | Invocable: queries `Attendee_Assignment_Detail__c` records for a processing log, formats them into structured text for the AI prompt |
| `force-app/main/default/classes/BuildFailureContext.cls-meta.xml` | Apex class metadata |
| `force-app/main/default/classes/BuildFailureContextTest.cls` | Tests for BuildFailureContext |
| `force-app/main/default/classes/BuildFailureContextTest.cls-meta.xml` | Test class metadata |
| `force-app/main/default/classes/CreateFollowUpTask.cls` | Invocable: queries Mac Kitchin's User record, inserts a Task with the AI summary as description |
| `force-app/main/default/classes/CreateFollowUpTask.cls-meta.xml` | Apex class metadata |
| `force-app/main/default/classes/CreateFollowUpTaskTest.cls` | Tests for CreateFollowUpTask |
| `force-app/main/default/classes/CreateFollowUpTaskTest.cls-meta.xml` | Test class metadata |
| `force-app/main/default/genAiPromptTemplates/Attendee_Assignment_Failure_Summary.genAiPromptTemplate-meta.xml` | GenAI prompt template: takes structured failure context, returns plain-English narrative |
| `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml` | Modified: adds `Decision_Needs_Task` on both branches, chains to BuildFailureContext → prompt → CreateFollowUpTask |

---

## Chunk 1: BuildFailureContext

### Task 1: BuildFailureContext — Test class

**Files:**
- Create: `force-app/main/default/classes/BuildFailureContextTest.cls`
- Create: `force-app/main/default/classes/BuildFailureContextTest.cls-meta.xml`

- [ ] **Step 1: Create the test class meta XML**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

Write to `force-app/main/default/classes/BuildFailureContextTest.cls-meta.xml`.

- [ ] **Step 2: Write the test class**

Write to `force-app/main/default/classes/BuildFailureContextTest.cls`:

```apex
/**
 * @description Tests for BuildFailureContext invocable
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

    // Create a processing log
    Attendee_Processing_Log__c log = new Attendee_Processing_Log__c(
      Opportunity__c = opp.Id,
      Processing_Type__c = 'Inbound Reply',
      Status__c = 'Partial Success',
      Processing_Date__c = System.now()
    );
    insert log;
  }

  private static Opportunity getTestOpportunity() {
    return [SELECT Id FROM Opportunity WHERE Name = 'Test Opp' LIMIT 1];
  }

  private static Attendee_Processing_Log__c getTestLog() {
    return [SELECT Id FROM Attendee_Processing_Log__c LIMIT 1];
  }

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

  @IsTest
  static void testNullProcessingLogId_returnsMinimalContext() {
    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = null;
    req.statusMessage = 'PARTIAL_ASSIGNED: assigned=1, notAssigned=1';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.buildContext(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    String output = results[0].formattedContext;
    System.assert(output.contains('Opportunity: Test Opp'), 'Should contain opp name');
    System.assert(output.contains('PARTIAL_ASSIGNED'), 'Should contain status message');
    System.assert(
      output.contains('No detailed assignment records are available'),
      'Should contain no-records message'
    );
  }

  @IsTest
  static void testNoDetailRecords_returnsMinimalContext() {
    Attendee_Processing_Log__c log = getTestLog();

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'ERROR: No attendees found.';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.buildContext(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    String output = results[0].formattedContext;
    System.assert(output.contains('Opportunity: Test Opp'));
    // No ASSIGNED or FAILED sections when no records exist
    System.assert(!output.contains('ASSIGNED ATTENDEES:'));
    System.assert(!output.contains('FAILED / SKIPPED ATTENDEES:'));
  }

  @IsTest
  static void testAssignedOnly_noFailureSection() {
    Attendee_Processing_Log__c log = getTestLog();

    Attendee_Assignment_Detail__c detail = new Attendee_Assignment_Detail__c(
      Processing_Log__c = log.Id,
      Assignment_Status__c = 'Assigned',
      Extracted_Name__c = 'Jane Doe',
      Extracted_Email__c = 'jane@example.com',
      Event_Name__c = 'BizBash MEGA',
      Product_Type__c = 'Association'
    );
    insert detail;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'SUCCESS_ASSIGNED: assigned=1';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.buildContext(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String output = results[0].formattedContext;
    System.assert(output.contains('ASSIGNED ATTENDEES:'), 'Should have assigned section');
    System.assert(output.contains('Jane Doe'), 'Should contain assigned attendee name');
    System.assert(!output.contains('FAILED / SKIPPED ATTENDEES:'), 'No failure section expected');
  }

  @IsTest
  static void testMixedAssignedFailedSkipped_formatsCorrectly() {
    Attendee_Processing_Log__c log = getTestLog();

    List<Attendee_Assignment_Detail__c> details = new List<Attendee_Assignment_Detail__c>{
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Assigned',
        Extracted_Name__c = 'Jane Doe',
        Extracted_Email__c = 'jane@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Association'
      ),
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Skipped',
        Extracted_Name__c = 'John Smith',
        Extracted_Email__c = 'john@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Non-Appointment Taker',
        Assignment_Error__c = 'No available open registration slot for attendee.'
      ),
      new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Failed',
        Extracted_Name__c = 'Alice Jones',
        Extracted_Email__c = 'alice@example.com',
        Event_Name__c = 'BizBash MEGA',
        Product_Type__c = 'Association',
        Assignment_Error__c = 'FIELD_CUSTOM_VALIDATION_EXCEPTION - Email invalid'
      )
    };
    insert details;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'PARTIAL_ASSIGNED: assigned=1, notAssigned=2';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.buildContext(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String output = results[0].formattedContext;
    System.assert(output.contains('ASSIGNED ATTENDEES:'), 'Should have assigned section');
    System.assert(output.contains('Jane Doe'), 'Should list assigned attendee');
    System.assert(output.contains('FAILED / SKIPPED ATTENDEES:'), 'Should have failure section');
    System.assert(output.contains('John Smith'), 'Should list skipped attendee');
    System.assert(output.contains('Alice Jones'), 'Should list failed attendee');
    System.assert(output.contains('No available open registration slot'), 'Should include skip reason');
    System.assert(output.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION'), 'Should include DML error');
  }

  @IsTest
  static void testTruncation_capsAt10000Characters() {
    Attendee_Processing_Log__c log = getTestLog();

    // Create enough detail records to exceed 10,000 characters
    List<Attendee_Assignment_Detail__c> details = new List<Attendee_Assignment_Detail__c>();
    for (Integer i = 0; i < 200; i++) {
      details.add(new Attendee_Assignment_Detail__c(
        Processing_Log__c = log.Id,
        Assignment_Status__c = 'Skipped',
        Extracted_Name__c = 'Attendee Number ' + i + ' With A Very Long Name To Fill Up Characters',
        Extracted_Email__c = 'attendee' + i + '@example-long-domain-name-for-testing-truncation.com',
        Event_Name__c = 'Very Long Event Name That Takes Up Space ' + i,
        Product_Type__c = 'Association',
        Assignment_Error__c = 'No available open registration slot for attendee. This is a detailed error message that takes up space.'
      ));
    }
    insert details;

    BuildFailureContext.Request req = new BuildFailureContext.Request();
    req.processingLogId = log.Id;
    req.statusMessage = 'ERROR: All slots full.';
    req.opportunityName = 'Test Opp';

    Test.startTest();
    List<BuildFailureContext.Result> results = BuildFailureContext.buildContext(
      new List<BuildFailureContext.Request>{ req }
    );
    Test.stopTest();

    String output = results[0].formattedContext;
    System.assert(output.length() <= 10000, 'Output should be at most 10,000 characters, was: ' + output.length());
    System.assert(output.contains('[truncated'), 'Should contain truncation marker');
    System.assert(output.contains('Opportunity: Test Opp'), 'Header should always be preserved');
  }
}
```

- [ ] **Step 3: Commit test class**

```bash
git add force-app/main/default/classes/BuildFailureContextTest.cls force-app/main/default/classes/BuildFailureContextTest.cls-meta.xml
git commit -m "test: add BuildFailureContextTest test class (red)"
```

### Task 2: BuildFailureContext — Implementation

**Files:**
- Create: `force-app/main/default/classes/BuildFailureContext.cls`
- Create: `force-app/main/default/classes/BuildFailureContext.cls-meta.xml`

- [ ] **Step 1: Create the meta XML**

Write to `force-app/main/default/classes/BuildFailureContext.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Write the implementation**

Write to `force-app/main/default/classes/BuildFailureContext.cls`:

```apex
/**
 * @description Invocable Apex that queries Attendee_Assignment_Detail__c records for a processing log
 * and formats them into structured plain text for use as AI prompt input.
 * @group Attendee Processing
 */
public with sharing class BuildFailureContext {
  @TestVisible
  private static final Integer MAX_OUTPUT_LENGTH = 10000;

  public class Request {
    @InvocableVariable(label='Processing Log ID')
    public Id processingLogId;

    @InvocableVariable(label='Status Message' required=true)
    public String statusMessage;

    @InvocableVariable(label='Opportunity Name' required=true)
    public String opportunityName;
  }

  public class Result {
    @InvocableVariable(label='Formatted Context')
    public String formattedContext;
  }

  @InvocableMethod(
    label='Build Failure Context'
    description='Queries assignment detail records and formats them as structured text for the AI failure summary prompt.'
    category='Attendee Processing'
  )
  public static List<Result> buildContext(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request req : requests) {
      results.add(buildSingle(req));
    }
    return results;
  }

  private static Result buildSingle(Request req) {
    Result r = new Result();
    String header = 'Opportunity: ' + (req.opportunityName != null ? req.opportunityName : '') + '\n' +
      'Overall Status: ' + (req.statusMessage != null ? req.statusMessage : '') + '\n';

    if (req.processingLogId == null) {
      r.formattedContext = header + '\nNo detailed assignment records are available for this run.';
      return r;
    }

    List<Attendee_Assignment_Detail__c> assigned = [
      SELECT Extracted_Name__c, Extracted_Email__c, Event_Name__c, Product_Type__c
      FROM Attendee_Assignment_Detail__c
      WHERE Processing_Log__c = :req.processingLogId AND Assignment_Status__c = 'Assigned'
      WITH USER_MODE
      ORDER BY CreatedDate ASC
    ];

    List<Attendee_Assignment_Detail__c> failedSkipped = [
      SELECT Extracted_Name__c, Extracted_Email__c, Event_Name__c, Product_Type__c, Assignment_Error__c, Assignment_Status__c
      FROM Attendee_Assignment_Detail__c
      WHERE Processing_Log__c = :req.processingLogId AND Assignment_Status__c IN ('Failed', 'Skipped')
      WITH USER_MODE
      ORDER BY CreatedDate ASC
    ];

    if (assigned.isEmpty() && failedSkipped.isEmpty()) {
      r.formattedContext = header + '\nNo detailed assignment records are available for this run.';
      return r;
    }

    List<String> assignedLines = new List<String>();
    for (Integer i = 0; i < assigned.size(); i++) {
      Attendee_Assignment_Detail__c d = assigned[i];
      assignedLines.add(
        (i + 1) + '. ' + safe(d.Extracted_Name__c) + ' (' + safe(d.Extracted_Email__c) + ')' +
        ' \u2014 Event: ' + safe(d.Event_Name__c) + ' | Product: ' + safe(d.Product_Type__c)
      );
    }

    List<String> failedLines = new List<String>();
    for (Integer i = 0; i < failedSkipped.size(); i++) {
      Attendee_Assignment_Detail__c d = failedSkipped[i];
      String line = (i + 1) + '. ' + safe(d.Extracted_Name__c) + ' (' + safe(d.Extracted_Email__c) + ')' +
        ' \u2014 Event: ' + safe(d.Event_Name__c) + ' | Product: ' + safe(d.Product_Type__c);
      if (String.isNotBlank(d.Assignment_Error__c)) {
        line += '\n   Reason: ' + d.Assignment_Error__c;
      }
      failedLines.add(line);
    }

    String fullOutput = header;
    if (!assignedLines.isEmpty()) {
      fullOutput += '\nASSIGNED ATTENDEES:\n' + String.join(assignedLines, '\n') + '\n';
    }
    if (!failedLines.isEmpty()) {
      fullOutput += '\nFAILED / SKIPPED ATTENDEES:\n' + String.join(failedLines, '\n') + '\n';
    }

    r.formattedContext = truncateIfNeeded(fullOutput, header, assignedLines, failedLines);
    return r;
  }

  private static String truncateIfNeeded(
    String fullOutput,
    String header,
    List<String> assignedLines,
    List<String> failedLines
  ) {
    if (fullOutput.length() <= MAX_OUTPUT_LENGTH) {
      return fullOutput;
    }

    // Strategy: remove lines from the middle of failed section first, then assigned section
    List<String> trimmedFailed = trimFromMiddle(failedLines);
    List<String> trimmedAssigned = assignedLines;
    String marker = '\n[truncated \u2014 some records omitted]\n';

    String attempt = buildOutput(header, trimmedAssigned, trimmedFailed, marker);
    if (attempt.length() <= MAX_OUTPUT_LENGTH) {
      return attempt;
    }

    // Also trim assigned section
    trimmedAssigned = trimFromMiddle(assignedLines);
    String assignedMarker = '\n[truncated \u2014 some assigned records omitted]\n';

    // Keep reducing until it fits
    while (attempt.length() > MAX_OUTPUT_LENGTH && (trimmedFailed.size() > 1 || trimmedAssigned.size() > 1)) {
      if (trimmedFailed.size() > 1) {
        trimmedFailed = trimFromMiddle(trimmedFailed);
      } else if (trimmedAssigned.size() > 1) {
        trimmedAssigned = trimFromMiddle(trimmedAssigned);
      }
      attempt = buildOutput(header, trimmedAssigned, trimmedFailed,
        (trimmedAssigned.size() < assignedLines.size() ? assignedMarker : '') +
        (trimmedFailed.size() < failedLines.size() ? marker : ''));
    }

    // Final safety: hard truncate if still over
    if (attempt.length() > MAX_OUTPUT_LENGTH) {
      attempt = attempt.left(MAX_OUTPUT_LENGTH - 30) + '\n[truncated \u2014 output too large]';
    }

    return attempt;
  }

  private static List<String> trimFromMiddle(List<String> lines) {
    if (lines.size() <= 2) {
      return lines;
    }
    // Keep first and last, remove one from the middle
    List<String> result = new List<String>();
    Integer midpoint = lines.size() / 2;
    for (Integer i = 0; i < lines.size(); i++) {
      if (i != midpoint) {
        result.add(lines[i]);
      }
    }
    return result;
  }

  private static String buildOutput(
    String header,
    List<String> assignedLines,
    List<String> failedLines,
    String markers
  ) {
    String output = header;
    if (!assignedLines.isEmpty()) {
      output += '\nASSIGNED ATTENDEES:\n' + String.join(assignedLines, '\n') + '\n';
    }
    if (!failedLines.isEmpty()) {
      output += '\nFAILED / SKIPPED ATTENDEES:\n' + String.join(failedLines, '\n') + '\n';
    }
    if (String.isNotBlank(markers)) {
      output += markers;
    }
    return output;
  }

  private static String safe(String val) {
    return String.isNotBlank(val) ? val : '';
  }
}
```

- [ ] **Step 3: Run tests locally with lint**

```bash
npm run lint
```

Expected: No lint errors on new files.

- [ ] **Step 4: Commit implementation**

```bash
git add force-app/main/default/classes/BuildFailureContext.cls force-app/main/default/classes/BuildFailureContext.cls-meta.xml
git commit -m "feat: add BuildFailureContext invocable Apex class"
```

---

## Chunk 2: CreateFollowUpTask

### Task 3: CreateFollowUpTask — Test class

**Files:**
- Create: `force-app/main/default/classes/CreateFollowUpTaskTest.cls`
- Create: `force-app/main/default/classes/CreateFollowUpTaskTest.cls-meta.xml`

- [ ] **Step 1: Create the test class meta XML**

Write to `force-app/main/default/classes/CreateFollowUpTaskTest.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Write the test class**

Write to `force-app/main/default/classes/CreateFollowUpTaskTest.cls`:

```apex
/**
 * @description Tests for CreateFollowUpTask invocable
 */
@IsTest
private class CreateFollowUpTaskTest {
  @TestSetup
  static void setup() {
    Id stdPbId = Test.getStandardPricebookId();

    Account acc = new Account(Name = 'Task Test Acme');
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'Task Test Opp',
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
    return [SELECT Id FROM Opportunity WHERE Name = 'Task Test Opp' LIMIT 1];
  }

  @IsTest
  static void testCreatesTaskWithAiSummary() {
    Opportunity opp = getTestOpportunity();

    CreateFollowUpTask.Request req = new CreateFollowUpTask.Request();
    req.opportunityId = opp.Id;
    req.aiSummary = 'The system processed 3 attendees but only 1 was assigned successfully.';
    req.opportunityName = 'Task Test Opp';
    req.statusMessage = 'PARTIAL_ASSIGNED: assigned=1, notAssigned=2';

    Test.startTest();
    List<CreateFollowUpTask.Result> results = CreateFollowUpTask.createTask(
      new List<CreateFollowUpTask.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertEquals(true, results[0].success, 'Task creation should succeed: ' + results[0].errorMessage);

    List<Task> tasks = [
      SELECT Subject, WhatId, OwnerId, ActivityDate, Status, Priority, Description, Type
      FROM Task
      WHERE WhatId = :opp.Id
    ];
    System.assertEquals(1, tasks.size(), 'One task should be created');
    Task t = tasks[0];
    System.assert(t.Subject.startsWith('Review Attendee Assignment Failures'), 'Subject should start with expected prefix');
    System.assert(t.Subject.contains('Task Test Opp'), 'Subject should contain opportunity name');
    System.assertEquals(opp.Id, t.WhatId, 'WhatId should be the Opportunity');
    System.assertEquals(Date.today().addDays(30), t.ActivityDate, 'Due date should be today + 30');
    System.assertEquals('Not Started', t.Status);
    System.assertEquals('Normal', t.Priority);
    System.assertEquals('Other', t.Type);
    System.assert(t.Description.contains('3 attendees'), 'Description should contain AI summary');
  }

  @IsTest
  static void testFallbackDescription_whenAiSummaryBlank() {
    Opportunity opp = getTestOpportunity();

    CreateFollowUpTask.Request req = new CreateFollowUpTask.Request();
    req.opportunityId = opp.Id;
    req.aiSummary = '';
    req.opportunityName = 'Task Test Opp';
    req.statusMessage = 'ERROR: No slots available.';

    Test.startTest();
    List<CreateFollowUpTask.Result> results = CreateFollowUpTask.createTask(
      new List<CreateFollowUpTask.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success);

    Task t = [SELECT Description FROM Task WHERE WhatId = :opp.Id LIMIT 1];
    System.assert(t.Description.contains('No slots available'), 'Fallback should include statusMessage');
    System.assert(t.Description.contains('AI summary was unavailable'), 'Fallback should note AI was unavailable');
  }

  @IsTest
  static void testSubjectTruncation_longOpportunityName() {
    Opportunity opp = getTestOpportunity();

    // Build a name longer than 200 characters
    String longName = '';
    for (Integer i = 0; i < 25; i++) {
      longName += 'LongName' + i;
    }

    CreateFollowUpTask.Request req = new CreateFollowUpTask.Request();
    req.opportunityId = opp.Id;
    req.aiSummary = 'Summary text.';
    req.opportunityName = longName;
    req.statusMessage = 'ERROR: test';

    Test.startTest();
    List<CreateFollowUpTask.Result> results = CreateFollowUpTask.createTask(
      new List<CreateFollowUpTask.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success);

    Task t = [SELECT Subject FROM Task WHERE WhatId = :opp.Id LIMIT 1];
    System.assert(t.Subject.length() <= 255, 'Subject must not exceed 255 chars, was: ' + t.Subject.length());
  }

  @IsTest
  static void testFallbackOwner_whenEmailNotFound() {
    Opportunity opp = getTestOpportunity();

    // The test org almost certainly won't have mac.kitchin@informa.com as a User.
    // The class should fall back to UserInfo.getUserId().
    CreateFollowUpTask.Request req = new CreateFollowUpTask.Request();
    req.opportunityId = opp.Id;
    req.aiSummary = 'Test summary.';
    req.opportunityName = 'Task Test Opp';
    req.statusMessage = 'test status';

    Test.startTest();
    List<CreateFollowUpTask.Result> results = CreateFollowUpTask.createTask(
      new List<CreateFollowUpTask.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(true, results[0].success, 'Should succeed with fallback owner');

    Task t = [SELECT OwnerId FROM Task WHERE WhatId = :opp.Id LIMIT 1];
    System.assertEquals(UserInfo.getUserId(), t.OwnerId, 'Should fall back to running user');
  }
}
```

- [ ] **Step 3: Commit test class**

```bash
git add force-app/main/default/classes/CreateFollowUpTaskTest.cls force-app/main/default/classes/CreateFollowUpTaskTest.cls-meta.xml
git commit -m "test: add CreateFollowUpTaskTest test class (red)"
```

### Task 4: CreateFollowUpTask — Implementation

**Files:**
- Create: `force-app/main/default/classes/CreateFollowUpTask.cls`
- Create: `force-app/main/default/classes/CreateFollowUpTask.cls-meta.xml`

- [ ] **Step 1: Create the meta XML**

Write to `force-app/main/default/classes/CreateFollowUpTask.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Write the implementation**

Write to `force-app/main/default/classes/CreateFollowUpTask.cls`:

```apex
/**
 * @description Invocable Apex that creates a Salesforce Task assigned to Mac Kitchin
 * when attendee assignment produces a Partial Success or Failed result.
 * The Task is linked to the Opportunity and contains an AI-generated summary.
 * @group Attendee Processing
 */
public with sharing class CreateFollowUpTask {
  @TestVisible
  private static final String ASSIGNEE_EMAIL = 'mac.kitchin@informa.com';
  private static final String SUBJECT_PREFIX = 'Review Attendee Assignment Failures \u2014 ';
  private static final Integer MAX_NAME_IN_SUBJECT = 200;

  public class Request {
    @InvocableVariable(label='Opportunity ID' required=true)
    public Id opportunityId;

    @InvocableVariable(label='AI Summary' description='AI-generated narrative for the Task description')
    public String aiSummary;

    @InvocableVariable(label='Opportunity Name' required=true)
    public String opportunityName;

    @InvocableVariable(label='Status Message' description='Fallback if AI summary is blank')
    public String statusMessage;
  }

  public class Result {
    @InvocableVariable(label='Success')
    public Boolean success;

    @InvocableVariable(label='Task ID')
    public Id taskId;

    @InvocableVariable(label='Error Message')
    public String errorMessage;
  }

  @InvocableMethod(
    label='Create Follow-Up Task'
    description='Creates a Task assigned to Mac Kitchin on the Opportunity when attendee assignment has failures.'
    category='Attendee Processing'
  )
  public static List<Result> createTask(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request req : requests) {
      results.add(createSingle(req));
    }
    return results;
  }

  private static Result createSingle(Request req) {
    Result r = new Result();
    try {
      // Resolve assignee User ID
      Id ownerId = resolveOwner();

      // Build description
      String description;
      if (String.isNotBlank(req.aiSummary)) {
        description = req.aiSummary;
      } else {
        description = 'Attendee assignment completed with status: ' +
          (req.statusMessage != null ? req.statusMessage : 'Unknown') +
          '. AI summary was unavailable.';
      }

      // Build subject (truncate opportunity name to fit within 255-char limit)
      String oppName = req.opportunityName != null ? req.opportunityName.left(MAX_NAME_IN_SUBJECT) : '';
      String subject = SUBJECT_PREFIX + oppName;

      Task t = new Task(
        Subject = subject,
        WhatId = req.opportunityId,
        OwnerId = ownerId,
        ActivityDate = Date.today().addDays(30),
        Status = 'Not Started',
        Priority = 'Normal',
        Description = description,
        Type = 'Other'
      );

      Database.SaveResult sr = Database.insert(t, true, AccessLevel.SYSTEM_MODE);
      r.success = sr.isSuccess();
      r.taskId = t.Id;
      if (!sr.isSuccess()) {
        List<String> errs = new List<String>();
        for (Database.Error e : sr.getErrors()) {
          errs.add(e.getStatusCode() + ' - ' + e.getMessage());
        }
        r.errorMessage = String.join(errs, ' | ');
      }
    } catch (Exception e) {
      r.success = false;
      r.errorMessage = e.getMessage();
    }
    return r;
  }

  private static Id resolveOwner() {
    List<User> users = [
      SELECT Id
      FROM User
      WHERE Email = :ASSIGNEE_EMAIL AND IsActive = true
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (!users.isEmpty()) {
      return users[0].Id;
    }

    System.debug(
      LoggingLevel.WARN,
      'CreateFollowUpTask: User with email ' + ASSIGNEE_EMAIL + ' not found. Falling back to running user.'
    );
    return UserInfo.getUserId();
  }
}
```

- [ ] **Step 3: Run lint**

```bash
npm run lint
```

Expected: No lint errors.

- [ ] **Step 4: Commit implementation**

```bash
git add force-app/main/default/classes/CreateFollowUpTask.cls force-app/main/default/classes/CreateFollowUpTask.cls-meta.xml
git commit -m "feat: add CreateFollowUpTask invocable Apex class"
```

---

## Chunk 3: GenAI Prompt Template

### Task 5: Attendee_Assignment_Failure_Summary prompt template

**Files:**
- Create: `force-app/main/default/genAiPromptTemplates/Attendee_Assignment_Failure_Summary.genAiPromptTemplate-meta.xml`

**Reference:** Study the existing template at `force-app/main/default/genAiPromptTemplates/Extract_Attendee_Information.genAiPromptTemplate-meta.xml` for the XML structure. The new template differs in that it takes a free-text String input (not an SObject reference).

- [ ] **Step 1: Write the prompt template XML**

Write to `force-app/main/default/genAiPromptTemplates/Attendee_Assignment_Failure_Summary.genAiPromptTemplate-meta.xml`:

**Important:** The `versionIdentifier` value must be unique. Use a placeholder that the deployment will auto-generate, or compute a hash. For initial deployment, use a simple identifier. The `activeVersionIdentifier` must match the version you want active.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<GenAiPromptTemplate xmlns="http://soap.sforce.com/2006/04/metadata">
    <activeVersionIdentifier>Attendee_Assignment_Failure_Summary_v1</activeVersionIdentifier>
    <description>Generates a plain-English summary of attendee assignment failures for use as a Salesforce Task description.</description>
    <developerName>Attendee_Assignment_Failure_Summary</developerName>
    <masterLabel>Attendee Assignment Failure Summary</masterLabel>
    <templateVersions>
        <content>You are an operations assistant for Connect Meetings event registrations.

Your task is to write a clear, plain-English summary of an attendee assignment processing run that had failures. This summary will be placed into a Salesforce Task description for a human operator to review.

INSTRUCTIONS:
1. Read the structured data below carefully.
2. Write a concise summary that explains:
   - How many attendees were provided and how many were successfully assigned
   - Who was assigned successfully (if anyone), including their name, email, event, and product type
   - Who could NOT be assigned, with a plain-English explanation of WHY each one failed
3. For system errors (DML, validation rule exceptions), translate the technical error into plain English. For example:
   - &quot;No available open registration slot for attendee&quot; means there were more attendees than open registration line items on the opportunity
   - &quot;FIELD_CUSTOM_VALIDATION_EXCEPTION&quot; means a validation rule on the record prevented the update
4. End with a brief recommendation of what the operator should do next (e.g., add more registration products, manually assign the remaining attendees, check validation rules)

OUTPUT FORMAT:
- Write clean prose suitable for a Salesforce Task description
- Do NOT use markdown, code blocks, backticks, or special formatting
- Use plain dashes (-) for list items
- Keep it between 150 and 400 words
- Be factual and specific — include names and emails

ASSIGNMENT DATA:
{!$Input:FailureContext}
</content>
        <inputs>
            <apiName>FailureContext</apiName>
            <definition>primitive://String</definition>
            <masterLabel>Failure Context</masterLabel>
            <referenceName>Input:FailureContext</referenceName>
            <required>true</required>
        </inputs>
        <primaryModel>sfdc_ai__DefaultBedrockAnthropicClaude45Haiku</primaryModel>
        <status>Published</status>
        <versionIdentifier>Attendee_Assignment_Failure_Summary_v1</versionIdentifier>
    </templateVersions>
    <type>einstein_gpt__flex</type>
    <visibility>Global</visibility>
</GenAiPromptTemplate>
```

**Key differences from `Extract_Attendee_Information`:**
- Input uses `definition>primitive://String</definition>` instead of `SOBJECT://EmailMessage` — this is a free-text string input, not an SObject reference.
- `referenceName` is `Input:FailureContext` which is how the Flow maps `varFormattedContext` to it.

- [ ] **Step 2: Commit**

```bash
git add force-app/main/default/genAiPromptTemplates/Attendee_Assignment_Failure_Summary.genAiPromptTemplate-meta.xml
git commit -m "feat: add Attendee_Assignment_Failure_Summary GenAI prompt template"
```

---

## Chunk 4: Flow Modifications

### Task 6: Modify the Flow XML

**Files:**
- Modify: `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml`

This task modifies the existing flow to add the `Decision_Needs_Task` decision and the three new action steps. The flow XML is declarative — each change is a specific block of XML to insert or modify.

**Understanding the current flow structure (critical context):**

The current flow has this decision at line 516:
```xml
<decisions>
    <name>Decision_Is_Success</name>
    ...
    <defaultConnector> → Update_Processing_Log_Failure_Result</defaultConnector>
    <rules>
        <name>Outcome_Success</name>
        <conditions> varIsSuccess = true </conditions>
        <connector> → Update_Processing_Log_Success_Result</connector>
    </rules>
</decisions>
```

The success path ends at `Action_Send_Success_Notification` (no outbound connector — terminal node).
The failure path ends at `Action_Send_Failure_Notification` (no outbound connector — terminal node).

We need to:
1. Add `varFormattedContext` variable
2. Add a `Decision_Needs_Task` decision node
3. Add `Build_Failure_Context` action call
4. Add `Generate_Failure_Summary` action call (generatePromptResponse)
5. Add `Create_Follow_Up_Task` action call
6. Wire `Action_Send_Success_Notification` → `Decision_Needs_Task` (add connector)
7. Wire `Action_Send_Failure_Notification` → `Decision_Needs_Task` (add connector)

- [ ] **Step 1: Add the `varFormattedContext` variable**

Add this variable to the `<variables>` section of the flow (after the existing `varStatusMessage` variable block, before the closing `</Flow>` tag):

```xml
    <variables>
        <name>varFormattedContext</name>
        <dataType>String</dataType>
        <isCollection>false</isCollection>
        <isInput>false</isInput>
        <isOutput>false</isOutput>
    </variables>
```

- [ ] **Step 2: Add the `Decision_Needs_Task` decision node**

Add this decision block after the existing `Decision_Is_Success` decisions block:

```xml
    <decisions>
        <description>Checks whether a follow-up Task should be created. Fires for Partial Success and Failed outcomes.</description>
        <name>Decision_Needs_Task</name>
        <label>Needs Follow-Up Task?</label>
        <locationX>176</locationX>
        <locationY>755</locationY>
        <defaultConnectorLabel>No Task Needed</defaultConnectorLabel>
        <rules>
            <name>Outcome_Needs_Task</name>
            <conditionLogic>and</conditionLogic>
            <conditions>
                <leftValueReference>varFinalStatus</leftValueReference>
                <operator>NotEqualTo</operator>
                <rightValue>
                    <stringValue>Success</stringValue>
                </rightValue>
            </conditions>
            <connector>
                <targetReference>Build_Failure_Context</targetReference>
            </connector>
            <label>Task Needed</label>
        </rules>
    </decisions>
```

- [ ] **Step 3: Add the three new action calls**

Add these three action call blocks (after the existing action calls):

**Build_Failure_Context:**
```xml
    <actionCalls>
        <description>Queries assignment detail records and formats them for the AI summary prompt.</description>
        <name>Build_Failure_Context</name>
        <label>Build Failure Context</label>
        <locationX>50</locationX>
        <locationY>863</locationY>
        <actionName>BuildFailureContext</actionName>
        <actionType>apex</actionType>
        <connector>
            <targetReference>Generate_Failure_Summary</targetReference>
        </connector>
        <faultConnector>
            <targetReference>Assign_Fault_Message</targetReference>
        </faultConnector>
        <flowTransactionModel>CurrentTransaction</flowTransactionModel>
        <inputParameters>
            <name>processingLogId</name>
            <value>
                <elementReference>varProcessingLogId</elementReference>
            </value>
        </inputParameters>
        <inputParameters>
            <name>statusMessage</name>
            <value>
                <elementReference>varStatusMessage</elementReference>
            </value>
        </inputParameters>
        <inputParameters>
            <name>opportunityName</name>
            <value>
                <elementReference>Get_Opportunity_Details.Name</elementReference>
            </value>
        </inputParameters>
        <nameSegment>BuildFailureContext</nameSegment>
        <offset>0</offset>
        <outputParameters>
            <assignToReference>varFormattedContext</assignToReference>
            <name>formattedContext</name>
        </outputParameters>
    </actionCalls>
```

**Generate_Failure_Summary:**
```xml
    <actionCalls>
        <description>Calls the AI prompt template to generate a plain-English failure summary.</description>
        <name>Generate_Failure_Summary</name>
        <label>Generate Failure Summary</label>
        <locationX>50</locationX>
        <locationY>917</locationY>
        <actionName>Attendee_Assignment_Failure_Summary</actionName>
        <actionType>generatePromptResponse</actionType>
        <connector>
            <targetReference>Create_Follow_Up_Task</targetReference>
        </connector>
        <faultConnector>
            <targetReference>Assign_Fault_Message</targetReference>
        </faultConnector>
        <flowTransactionModel>CurrentTransaction</flowTransactionModel>
        <inputParameters>
            <name>Input:FailureContext</name>
            <value>
                <elementReference>varFormattedContext</elementReference>
            </value>
        </inputParameters>
        <nameSegment>Attendee_Assignment_Failure_Summary</nameSegment>
        <offset>0</offset>
        <storeOutputAutomatically>true</storeOutputAutomatically>
    </actionCalls>
```

**Create_Follow_Up_Task:**
```xml
    <actionCalls>
        <description>Creates a Salesforce Task assigned to Mac Kitchin with the AI-generated failure summary.</description>
        <name>Create_Follow_Up_Task</name>
        <label>Create Follow-Up Task</label>
        <locationX>50</locationX>
        <locationY>971</locationY>
        <actionName>CreateFollowUpTask</actionName>
        <actionType>apex</actionType>
        <faultConnector>
            <targetReference>Assign_Fault_Message</targetReference>
        </faultConnector>
        <flowTransactionModel>CurrentTransaction</flowTransactionModel>
        <inputParameters>
            <name>opportunityId</name>
            <value>
                <elementReference>$Record.RelatedToId</elementReference>
            </value>
        </inputParameters>
        <inputParameters>
            <name>aiSummary</name>
            <value>
                <elementReference>Generate_Failure_Summary.promptResponse</elementReference>
            </value>
        </inputParameters>
        <inputParameters>
            <name>opportunityName</name>
            <value>
                <elementReference>Get_Opportunity_Details.Name</elementReference>
            </value>
        </inputParameters>
        <inputParameters>
            <name>statusMessage</name>
            <value>
                <elementReference>varStatusMessage</elementReference>
            </value>
        </inputParameters>
        <nameSegment>CreateFollowUpTask</nameSegment>
        <offset>0</offset>
    </actionCalls>
```

- [ ] **Step 4: Wire `Action_Send_Success_Notification` to `Decision_Needs_Task`**

The success email node is currently terminal (no `<connector>`). Add a connector to it.

Find the `Action_Send_Success_Notification` action call block (starts at line 69). After the closing `</inputParameters>` for `logEmailOnSend` and before `<nameSegment>`, add:

```xml
        <connector>
            <targetReference>Decision_Needs_Task</targetReference>
        </connector>
```

- [ ] **Step 5: Wire `Action_Send_Failure_Notification` to `Decision_Needs_Task`**

Same pattern — the failure email node is currently terminal. Add a connector.

Find the `Action_Send_Failure_Notification` action call block (starts at line 3). After the closing `</inputParameters>` for `logEmailOnSend` and before `<nameSegment>`, add:

```xml
        <connector>
            <targetReference>Decision_Needs_Task</targetReference>
        </connector>
```

- [ ] **Step 6: Run lint and format**

```bash
npm run prettier
npm run lint
```

Expected: No errors.

- [ ] **Step 7: Commit flow changes**

```bash
git add force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml
git commit -m "feat: add Decision_Needs_Task and follow-up task creation steps to attendee reply flow"
```

---

## Chunk 5: Deployment & Verification

### Task 7: Deploy and verify

**Files:** No new files — this task validates the full deployment.

- [ ] **Step 1: Deploy all new metadata to the org**

Run the deploy command with all new and modified metadata. Replace `<alias>` with the target org alias:

```bash
sf project deploy start -o <alias> \
  --metadata ApexClass:BuildFailureContext \
  --metadata ApexClass:BuildFailureContextTest \
  --metadata ApexClass:CreateFollowUpTask \
  --metadata ApexClass:CreateFollowUpTaskTest \
  --metadata ApexClass:AttendeeAssignmentDetailLogger \
  --metadata ApexClass:AttendeeProcessingLogger \
  --metadata ApexClass:AttendeeProcessingLogUpdater \
  --metadata ApexClass:ProcessAppointmentTakerAttendees \
  --metadata ApexClass:ProcessAppointmentTakerAttendeesTest \
  --metadata ApexClass:AttendeeProcessingLoggerTest \
  --metadata ApexClass:AttendeeReplyEmailHandler \
  --metadata ApexClass:AttendeeReplyEmailHandlerTest \
  --metadata GenAiPromptTemplate:Attendee_Assignment_Failure_Summary \
  --metadata GenAiPromptTemplate:Extract_Attendee_Information \
  --metadata CustomObject:Attendee_Processing_Log__c \
  --metadata CustomObject:Attendee_Assignment_Detail__c \
  --metadata ReportType:Attendee_Processing_with_Details \
  --metadata Flow:Event_Registration_Process_Attendee_Reply \
  --test-level RunSpecifiedTests \
  --tests BuildFailureContextTest \
  --tests CreateFollowUpTaskTest \
  --tests ProcessAppointmentTakerAttendeesTest \
  --tests AttendeeProcessingLoggerTest \
  --tests AttendeeReplyEmailHandlerTest
```

Expected: All tests pass. Deployment succeeds.

- [ ] **Step 2: Activate the flow**

If the flow is not auto-activated by deployment, deploy the flow definition:

```bash
sf project deploy start -o <alias> \
  --metadata FlowDefinition:Event_Registration_Process_Attendee_Reply \
  --test-level RunSpecifiedTests \
  --tests BuildFailureContextTest \
  --tests CreateFollowUpTaskTest
```

- [ ] **Step 3: Verify in Flow Builder**

Open Flow Builder in the target org and verify:
1. `Decision_Needs_Task` node appears after both email send nodes
2. Both `Action_Send_Success_Notification` and `Action_Send_Failure_Notification` connect to `Decision_Needs_Task`
3. The "Task Needed" path chains: `Build_Failure_Context` → `Generate_Failure_Summary` → `Create_Follow_Up_Task`
4. All three new action steps have fault connectors to `Assign_Fault_Message`

- [ ] **Step 4: Update README deployment section**

Add the new classes and prompt template to the deployment command in `README.md`:

In the `## Deployment` section, add these lines to the `sf project deploy start` command:
```
  --metadata ApexClass:BuildFailureContext \
  --metadata ApexClass:BuildFailureContextTest \
  --metadata ApexClass:CreateFollowUpTask \
  --metadata ApexClass:CreateFollowUpTaskTest \
  --metadata GenAiPromptTemplate:Attendee_Assignment_Failure_Summary \
```

And add these test flags:
```
  --tests BuildFailureContextTest \
  --tests CreateFollowUpTaskTest
```

Also add to the **Component Reference** table:

| `BuildFailureContext` | Apex (Invocable) | Formats assignment detail records into structured text for AI prompt |
| `CreateFollowUpTask` | Apex (Invocable) | Creates a follow-up Task on the Opportunity when assignment has failures |
| `Attendee_Assignment_Failure_Summary` | GenAI Prompt Template | Generates plain-English failure summary from structured assignment data |

- [ ] **Step 5: Commit README updates**

```bash
git add README.md
git commit -m "docs: add new failure task components to README"
```
