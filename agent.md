# Attendee Info Agent — Build Reference

Complete technical reference for replicating the Attendee Info Agent: a Salesforce automation that collects event attendee details from signer contacts via AI-parsed email replies.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [End-to-End Flow](#end-to-end-flow)
3. [Prerequisites & Authentication](#prerequisites--authentication)
4. [MCP Server](#mcp-server)
5. [Salesforce CLI Commands](#salesforce-cli-commands)
6. [Component Reference](#component-reference)
   - [Flow A — Send Registration Emails](#flow-a--send-registration-emails)
   - [Email Service — AttendeeReplyEmailHandler](#email-service--attendeereplyemailhandler)
   - [Flow B — Process Attendee Reply](#flow-b--process-attendee-reply)
   - [GenAI Prompt Template](#genai-prompt-template)
   - [Apex — ProcessAppointmentTakerAttendees](#apex--processappointmenttakerattendees)
   - [Apex — Audit Loggers](#apex--audit-loggers)
7. [Object Schemas](#object-schemas)
8. [Org-Specific IDs](#org-specific-ids)
9. [Step-by-Step Replication Guide](#step-by-step-replication-guide)
10. [Known Gotchas](#known-gotchas)

---

## System Overview

When an Opportunity is marked Closed Won with Appointment Taker products, this agent automatically:

1. Sends a templated email to the Signer Contact listing each registration slot
2. Receives the contact's reply via an Apex Email Service
3. Uses a GenAI prompt (Claude Haiku via Bedrock) to extract attendee JSON from the email body
4. Writes extracted names and emails to the matching `OpportunityLineItem` records
5. Logs every step to custom audit objects and sends a success/failure notification

**Target org:** `mac.kitchin@informa.com` (alias: `Connect Meetings`)
**API version:** `65.0` (source), `62.0` (flow XML)
**Email sender:** `attendeeinfo@informa.com` (Org-Wide Email Address)

---

## End-to-End Flow

```
Opportunity → Closed Won
        │  (StageName = Closed Won, Signer_Contact__c populated,
        │   External_Online_Order__c = false)
        ▼
[Flow A] Appointment_Taker_Send_Registration_Emails
        │  Queries OLIs where Product2Id IN supported product IDs
        │  AND (Attendee_Name__c = null OR Attendee_Email__c = null)
        │
        ├─ All slots filled → "Registration Details for your Event" email → END
        │
        └─ Missing slots → Follow-up email to Signer Contact
                Subject: "Action Required: Attendee Details for your
                          Event Registrations [REG:{OpportunityId}]"
                Sender: attendeeinfo@informa.com
                Body: numbered list of open slots with "Attendee Name:" / "Attendee Email:" blanks
                        │
                        ▼
              Signer replies with attendee details
                        │
                        ▼
[Exchange] attendeeinfo@informa.com → forwards all inbound → Salesforce Email Service address
                        │
                        ▼
[Apex Email Service] AttendeeReplyEmailHandler.handleInboundEmail()
        │  1. Checks subject contains SUBJECT_PATTERN
        │  2. Extracts [REG:OppId] token from subject (or falls back to 60-day lookback)
        │  3. Validates sender email matches original recipient (or same domain)
        │  4. Strips Outlook quoted content; keeps top reply unless "see below" detected
        │  5. Inserts incoming EmailMessage with RelatedToId = OpportunityId
                        │
                        ▼
[Flow B] Event_Registration_Process_Attendee_Reply  (triggered on EmailMessage After Create)
        │  Filters: Incoming = true, Subject contains SUBJECT_PATTERN
        │
        ├─ Get_Opportunity_Details (Record Lookup on Opportunity)
        ├─ Create_Attendee_Processing_Log (AttendeeProcessingLogger Apex)
        ├─ Extract_Attendee_Information (GenAI Prompt → promptResponse = JSON)
        ├─ Update_Processing_Log_After_AI (AttendeeProcessingLogUpdater Apex)
        ├─ Pass_to_Agent_to_Process_Attendees (ProcessAppointmentTakerAttendees Apex)
        │       jsonString = promptResponse
        │       opportunityId = $Record.RelatedToId
        │
        ├─ Decision: isSuccess = true → Update log (Success) → Send success email
        └─ Decision: isSuccess = false → Update log (Failed) → Send failure email
                        │
                        ▼
[Apex] ProcessAppointmentTakerAttendees
        │  1. Parses JSON array → List<Attendee> (first_name, last_name, email, event_name, product_type)
        │  2. Loads open OLIs via USER_MODE SOQL (Product2Id IN supported IDs, Attendee_Name__c = null)
        │  3. Bulk-resolves attendee emails → Contact IDs on the Opportunity's Account
        │  4. Group-fill assignment: match attendee event_name+product_type to OLI group key
        │  5. Fallback: positional assignment (next unclaimed open slot, CreatedDate ASC)
        │  6. DML update via SYSTEM_MODE (custom fields require elevated FLS)
        │  7. Logs each assignment attempt to Attendee_Assignment_Detail__c
        │  Returns: isSuccess, statusMessage, attendeesProvided/Assigned/NotAssigned, openSlotsRemaining
```

---

## Prerequisites & Authentication

### Install Salesforce CLI

```bash
npm install -g @salesforce/cli
sf --version
```

### Authenticate to org

**Generate auth URL** from any already-authenticated machine:
```bash
sf org display --verbose --json --target-org mac.kitchin@informa.com
# Copy the "sfdxAuthUrl" value from JSON output (starts with "force://")
```

**Authenticate in a new environment:**
```bash
echo "<sfdx-auth-url>" > /tmp/sf-auth.txt
sf org login sfdx-url --sfdx-url-file /tmp/sf-auth.txt --alias connect-meetings --set-default
rm /tmp/sf-auth.txt
sf org list   # verify
```

**Or use interactive web login (requires browser):**
```bash
sf org login web --alias connect-meetings --set-default
```

### Required Salesforce permissions

The running user needs:
- Read/Edit access on `Opportunity`, `OpportunityLineItem`, `EmailMessage`, `Contact`
- Read/Write on `Attendee_Processing_Log__c`, `Attendee_Assignment_Detail__c`
- Access to the `Extract_Attendee_Information` GenAI Prompt Template
- `Attendee_Name__c`, `Attendee_Email__c`, `Attendee_First_Name__c`, `Event_Attendee_Contact__c` FLS = Edit on OLI
  (The Apex uses SYSTEM_MODE for OLI DML to bypass FLS gaps on custom fields)

---

## MCP Server

During development, the Salesforce MCP server was used for org inspection and SOQL queries.

| Setting | Value |
|---|---|
| Server ID | `2cb05261-a470-48a3-a27b-2a1a01707c95` |
| Useful tools | `salesforce_query_records`, `salesforce_describe_object`, `salesforce_aggregate_query` |

**Note:** `GenAiPromptTemplate` is NOT queryable via SOQL. Use `sf project retrieve start --metadata` instead.

Example MCP queries used during build:

```soql
-- Find open Appointment Taker OLIs
SELECT Id, OpportunityId, Product2.Name, Attendee_Name__c, Attendee_Email__c,
       Event_Name__c, Product_Type__c
FROM OpportunityLineItem
WHERE Product2Id IN ('01t4X000004U13iQAC','01t4X000004U14AQAS','01t4X000004U148QAC')
  AND Attendee_Name__c = null
LIMIT 10

-- Check EmailMessage routing
SELECT Id, Subject, FromAddress, ToAddress, Incoming, RelatedToId, Status
FROM EmailMessage
WHERE Subject LIKE '%Action Required: Attendee Details%'
ORDER BY CreatedDate DESC
LIMIT 10

-- Verify Opportunity fields
SELECT Id, Name, StageName, Signer_Contact__c, Signer_Contact__r.Email,
       Sales_Territory__c, External_Online_Order__c
FROM Opportunity
WHERE Id = '<OppId>'
```

---

## Salesforce CLI Commands

### Deploy

```bash
# Deploy all Apex classes (with tests)
sf project deploy start \
  --source-dir force-app/main/default/classes \
  --target-org mac.kitchin@informa.com \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest,AttendeeReplyEmailHandlerTest,AttendeeProcessingLoggerTest

# Deploy a single flow
sf project deploy start \
  --source-dir "force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml" \
  --target-org mac.kitchin@informa.com

# Deploy custom objects
sf project deploy start \
  --source-dir force-app/main/default/objects \
  --target-org mac.kitchin@informa.com

# Deploy prompt templates
sf project deploy start \
  --source-dir force-app/main/default/genAiPromptTemplates \
  --target-org mac.kitchin@informa.com

# Deploy everything
sf project deploy start \
  --source-dir force-app \
  --target-org mac.kitchin@informa.com
```

### Retrieve (sync org → repo)

```bash
# Retrieve all in-scope metadata
sf project retrieve start \
  --metadata "Flow:Appointment_Taker_Send_Registration_Emails" \
  --metadata "Flow:Event_Registration_Process_Attendee_Reply" \
  --metadata "FlowDefinition:Event_Registration_Process_Attendee_Reply" \
  --metadata "GenAiPromptTemplate:Extract_Attendee_Information" \
  --metadata "GenAiPromptTemplate:Opportunity_Creation" \
  --target-org mac.kitchin@informa.com

# Retrieve custom objects
sf project retrieve start \
  --metadata "CustomObject:Attendee_Processing_Log__c" \
  --metadata "CustomObject:Attendee_Assignment_Detail__c" \
  --target-org mac.kitchin@informa.com

# Retrieve Apex classes
sf project retrieve start \
  --metadata "ApexClass:ProcessAppointmentTakerAttendees" \
  --metadata "ApexClass:AttendeeReplyEmailHandler" \
  --metadata "ApexClass:AttendeeProcessingLogger" \
  --metadata "ApexClass:AttendeeProcessingLogUpdater" \
  --metadata "ApexClass:AttendeeAssignmentDetailLogger" \
  --target-org mac.kitchin@informa.com
```

### Query

```bash
# Run SOQL from CLI
sf data query \
  --query "SELECT Id, Name, StageName FROM Opportunity WHERE StageName = 'Closed Won' LIMIT 5" \
  --target-org mac.kitchin@informa.com

# Run anonymous Apex
sf apex run \
  --file scripts/test-attendee-assignment.apex \
  --target-org mac.kitchin@informa.com

# View flow interviews (debug)
sf data query \
  --query "SELECT Id, InterviewLabel, Status, CreatedDate FROM FlowInterview ORDER BY CreatedDate DESC LIMIT 10" \
  --target-org mac.kitchin@informa.com
```

### Email Service Setup

The Email Service is configured in org Setup (not deployable via metadata):

1. **Setup → Email Services → New**
2. Name: `AttendeeReplyHandler`
3. Apex Class: `AttendeeReplyEmailHandler`
4. Accept Email From: (leave blank to accept from any address)
5. Copy the generated SF Email Service address (format: `...@...apex.salesforce.com`)

**Exchange forwarding:** In Exchange Admin Center, configure `attendeeinfo@informa.com` mailbox to forward all inbound mail to the SF Email Service address above.

---

## Component Reference

### Flow A — Send Registration Emails

**File:** `force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`
**API Name:** `Appointment_Taker_Send_Registration_Emails`
**Type:** AutoLaunchedFlow (Record-Triggered, Opportunity After Update)

#### Trigger conditions (all must be true, record must change to meet criteria)
| Field | Operator | Value |
|---|---|---|
| `StageName` | EqualTo | `Closed Won` |
| `Signer_Contact__c` | IsNull | `false` |
| `External_Online_Order__c` | EqualTo | `false` |

#### Logic
1. **Get_Appointment_Taker_OLIs** — queries `OpportunityLineItem` where `OpportunityId = $Record.Id` AND `Product2Id IN (01t4X000004U13iQAC, 01t4X000004U14AQAS, 01t4X000004U148QAC)` (filter logic: `1 AND (2 OR 3 OR 4)`)
2. **Assign_Init_Email_Body** — sets `varEmailBody` = `"Hi {FirstName}, Thank you for your purchase!..."`
3. **Loop_OLIs** — iterates `Get_Appointment_Taker_OLIs` ascending
   - **Assign_Increment_Total** — `varTotalCount += 1`
   - **Decision_Is_Missing** — if `Attendee_Name__c IS NULL OR Attendee_Email__c IS NULL`
     - Yes: **Assign_Build_Missing_Line** — appends numbered slot with Event/Type/blank fields to `varEmailBody`; `varMissingCount += 1`
4. **Decision_All_Registered**
   - `varMissingCount = 0 AND varTotalCount > 0` → **Action_Send_Completed_Email** (HTML confirmation)
   - `varMissingCount > 0 AND varTotalCount > 0` → **Assign_Append_Footer** → **Action_Send_Follow_Up_Email**

#### Email: Follow-up
- **To:** `$Record.Signer_Contact__r.Email`
- **Sender:** OrgWideEmailAddress `attendeeinfo@informa.com`
- **Subject:** `Action Required: Attendee Details for your Event Registrations [REG:{!$Record.Id}]`
- **Body:** `varEmailBody` (plain text, built dynamically per missing OLI)
- **logEmailOnSend:** `true` → creates an outgoing `EmailMessage` record linked to the Opportunity (required for reply matching)

#### Formula
```
Formula_Registration_Type:
IF(Product2Id = "01t4X000004U14AQAS", "Non-Appointment Taker",
  IF(Product2Id = "01t4X000004U148QAC", "Marketer", "Appointment Taker"))
```

---

### Email Service — AttendeeReplyEmailHandler

**File:** `force-app/main/default/classes/AttendeeReplyEmailHandler.cls`
**Interface:** `Messaging.InboundEmailHandler`

#### Key constants
| Constant | Value |
|---|---|
| `SUBJECT_PATTERN` | `Action Required: Attendee Details for your Event Registrations` |
| `REG_TOKEN_PATTERN` | `(?i)\[REG:([a-zA-Z0-9]{15,18})\]` |
| `OUTLOOK_REPLY_SEPARATOR` | `________________________________` (Outlook quoted section divider) |
| `MAX_PROMPT_BODY_CHARS` | `28000` (truncation cap for prompt safety) |
| `LEGACY_LOOKBACK_DAYS` | `60` (fallback search window when no token in subject) |

#### handleInboundEmail() logic
1. If subject does not contain `SUBJECT_PATTERN` → return success silently (ignore non-registration emails)
2. Normalize `fromAddress` (strips `<>` wrappers, lowercases)
3. **`preparePromptBody()`** — strips Outlook quoted section:
   - If top reply contains attendee signals (`"Attendee Name:"`, `"Attendee Email:"`, `"Event:"`, any email address) AND does NOT contain "please see below" → keep top reply only
   - Else if quoted section contains attendee signals → keep quoted section (user filled in the template in-place)
   - Cap at 28,000 chars; decode HTML entities (`&amp;`, `&lt;`, `&quot;`, `&#124;`, `&nbsp;`)
4. **Token route** (preferred): extract `[REG:OppId]` from subject → query outgoing `EmailMessage` where `RelatedToId = OppId AND Subject LIKE '%[REG:OppId]%'` → validate `ToAddress` contains sender email or same domain
5. **Legacy fallback**: query outgoing `EmailMessage` within 60 days by subject prefix + sender match
6. Insert incoming `EmailMessage`:
   - `Incoming = true`, `Status = '0'` (New)
   - `RelatedToId = opportunityId`
   - `ReplyToEmailMessageId = replyToEmailMessageId`
   - `TextBody = preparePromptBody(...)`, `HtmlBody = null`

#### SOQL queries inside handler
```soql
-- Token route
SELECT Id, ToAddress FROM EmailMessage
WHERE Incoming = FALSE
  AND RelatedToId = :opportunityId
  AND Subject LIKE :'%[REG:' + opportunityId + ']%'
ORDER BY CreatedDate DESC LIMIT 25

-- Legacy fallback
SELECT Id, RelatedToId, ToAddress FROM EmailMessage
WHERE Incoming = FALSE
  AND RelatedToId != NULL
  AND Subject LIKE :'Action Required: Attendee Details for your Event Registrations%'
  AND CreatedDate >= :System.now().addDays(-60)
ORDER BY CreatedDate DESC LIMIT 50
```

---

### Flow B — Process Attendee Reply

**File:** `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml`
**API Name:** `Event_Registration_Process_Attendee_Reply`
**Type:** AutoLaunchedFlow (Record-Triggered, EmailMessage After Create)
**Active version:** 4 (per `flowDefinition`)

#### Trigger conditions (EmailMessage After Create, all must be true)
| Field | Operator | Value |
|---|---|---|
| `Incoming` | EqualTo | `true` |
| `Subject` | Contains | `Action Required: Attendee Details for your Event Registrations` |

#### Element sequence
| # | Element | Type | Key config |
|---|---|---|---|
| 1 | `Get_Opportunity_Details` | Record Lookup | `Opportunity WHERE Id = $Record.RelatedToId` |
| 2 | `Create_Attendee_Processing_Log` | Apex Action | `AttendeeProcessingLogger` — processingType=`Inbound Reply`, status=`In Progress` |
| 3 | `Extract_Attendee_Information` | GenAI Prompt | input `Input:EmailMessage = $Record`; output stored automatically as `Extract_Attendee_Information.promptResponse` |
| 4 | `Update_Processing_Log_After_AI` | Apex Action | `AttendeeProcessingLogUpdater` — aiRawResponse=`promptResponse`, status=`In Progress` |
| 5 | `Pass_to_Agent_to_Process_Attendees` | Apex Action | `ProcessAppointmentTakerAttendees` — jsonString=`promptResponse`, opportunityId=`$Record.RelatedToId`, processingLogId=`varProcessingLogId` |
| 6 | `Decision_Is_Success` | Decision | `varIsSuccess = true` → success path; default → failure path |
| 7a | `Update_Processing_Log_Success_Result` | Apex Action | `AttendeeProcessingLogUpdater` with final counts + status |
| 7b | `Update_Processing_Log_Failure_Result` | Apex Action | `AttendeeProcessingLogUpdater` with error info |
| 8a | `Action_Send_Success_Notification` | emailSimple | To `mac.kitchin@informa.com`, subject `[Attendee Reply][SUCCESS] {Subject}` |
| 8b | `Action_Send_Failure_Notification` | emailSimple | To `mac.kitchin@informa.com`, subject `[Attendee Reply][FAILED] {Subject}` |

**Fault path:** Any element fault → `Assign_Fault_Message` (captures `$Flow.FaultMessage`) → `Update_Processing_Log_Failure_Fault` → `Action_Send_Failure_Notification`

#### Flow variables
| Variable | Type | Purpose |
|---|---|---|
| `varProcessingLogId` | String | ID of created `Attendee_Processing_Log__c` |
| `varIsSuccess` | Boolean | Output from ProcessAppointmentTakerAttendees |
| `varFinalStatus` | String | `Success` / `Partial Success` / `Failed` |
| `varStatusMessage` | String | Human-readable result or fault message |
| `varAttendeesProvided` | Number | Count from Apex |
| `varAttendeesAssigned` | Number | Count from Apex |
| `varAttendeesNotAssigned` | Number | Count from Apex |
| `varOpenSlotsRemaining` | Number | Count from Apex |
| `varErrorCategory` | String | Classification from Apex |

---

### GenAI Prompt Template

**File:** `force-app/main/default/genAiPromptTemplates/Extract_Attendee_Information.genAiPromptTemplate-meta.xml`
**API Name:** `Extract_Attendee_Information`
**Type:** `einstein_gpt__flex`
**Visibility:** Global
**Active version identifier:** `ZIlRtZe/8M3Mc2eeNQZh/XfIr52n4hFYfLjZbf7Z6ic=_4`

#### Input
| Field | Value |
|---|---|
| `apiName` | `EmailMessage` |
| `definition` | `SOBJECT://EmailMessage` |
| `referenceName` | `Input:EmailMessage` |
| `required` | `true` |

#### Version history

| Version | Model | Key changes |
|---|---|---|
| v1 | `sfdc_ai__DefaultOpenAIGPT4OmniMini` | Basic extraction: first name, last name, email from freeform body |
| v2 | `sfdc_ai__DefaultOpenAIGPT4OmniMini` | Structured format parsing: `Event: <name> | Type: <type>` sections; adds `event_name`, `product_type` fields |
| v3 | `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku` | Same as v1 but switched to Claude Haiku model |
| v4 (**active**) | `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku` | Same as v2 + fallback: if email is not structured, still extract any names/emails with `event_name`/`product_type` as empty strings |

#### Active prompt (v4)
```
You are an intelligent assistant for Connect Meetings.
Your goal is to extract event attendee information from an incoming email.

INSTRUCTIONS:
1. Analyze the email body below.
2. The email contains structured sections, each listing an event and its attendee details. Each section looks like:
  "Event: <event_name> | Type: <product_type>"
  followed by:
  "Attendee Name: <first_name> <last_name>"
  "Attendee Email: <email>"
3. Extract each attendee and return a raw, valid JSON list. Do not include any formatting, code blocks, or backticks.
4. Each JSON object must include: event_name, product_type, first_name, last_name, email.
5. If a section has no attendee name or email filled in, omit it from the output.
6. If the reply does not follow the structured format, still extract any names and emails you can identify,
   leaving event_name and product_type as empty strings.

Example output:
[{"event_name": "MEGA", "product_type": "Association", "first_name": "Matt", "last_name": "Johnson", "email": "matt.johnson@informa.com"}]

EMAIL DATA:
Subject: {!$Input:EmailMessage.Subject}
Body: {!$Input:EmailMessage.TextBody}

IMPORTANT: Return only the raw JSON string. Do not use markdown formatting, code blocks, or backticks.
```

#### Expected JSON output format
```json
[
  {
    "event_name": "BizBash MEGA",
    "product_type": "Association",
    "first_name": "Jane",
    "last_name": "Doe",
    "email": "jane.doe@company.com"
  }
]
```

#### How to invoke from Flow (metadata)
```xml
<actionCalls>
  <actionName>Extract_Attendee_Information</actionName>
  <actionType>generatePromptResponse</actionType>
  <inputParameters>
    <name>Input:EmailMessage</name>
    <value><elementReference>$Record</elementReference></value>
  </inputParameters>
  <storeOutputAutomatically>true</storeOutputAutomatically>
</actionCalls>
```
Access output as `{!Extract_Attendee_Information.promptResponse}`.

---

### Apex — ProcessAppointmentTakerAttendees

**File:** `force-app/main/default/classes/ProcessAppointmentTakerAttendees.cls`

#### Invocable method signature
```apex
@InvocableMethod(label='Process Appointment Taker Attendees')
public static List<Result> process(List<Request> requests)
```

#### Request inputs
| Variable | Type | Required | Description |
|---|---|---|---|
| `jsonString` | String | Yes | Raw JSON array from prompt template |
| `opportunityId` | String | Yes | 15/18-char Opportunity ID |
| `processingLogId` | Id | No | Links assignment details to parent log |

#### Result outputs
| Variable | Type | Description |
|---|---|---|
| `isSuccess` | Boolean | `true` if at least one attendee assigned, or no-op |
| `statusMessage` | String | Human-readable outcome with counts |
| `attendeesProvided` | Integer | Attendees in JSON input |
| `attendeesAssigned` | Integer | OLI updates that succeeded |
| `attendeesNotAssigned` | Integer | Attendees with no available slot or DML failure |
| `openSlotsRemaining` | Integer | Open OLI slots after assignment |
| `finalStatus` | String | `Success` / `Partial Success` / `Failed` |
| `errorCategory` | String | `None` / `Validation` / `DML` / `JSON Parse` / `AI Extraction` / `Other` |

#### Assignment algorithm
1. Parse JSON: requires `first_name` (non-blank) and `email` (non-blank); `last_name` optional
2. Load open OLIs: `Product2Id IN supported_ids AND Attendee_Name__c = null AND Attendee_Email__c = null ORDER BY CreatedDate ASC` (USER_MODE)
3. Resolve email→Contact: `SELECT Id, Email FROM Contact WHERE Email IN :attendeeEmails AND AccountId = :accountId` (USER_MODE)
4. Build group map: `"event_name_lower|product_type_lower"` → ordered list of open OLIs
5. For each attendee:
   - Try group match on `event_name + product_type`
   - Fallback: next unclaimed slot in creation order
6. DML: `Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE)` (partial success allowed)
7. Log each attempt to `Attendee_Assignment_Detail__c`

#### OLI fields written
| Field | Source |
|---|---|
| `Attendee_First_Name__c` | `attendee.firstName` |
| `Attendee_Name__c` | `firstName + ' ' + lastName` |
| `Attendee_Email__c` | `attendee.email` |
| `Event_Attendee_Contact__c` | Resolved Contact ID (if found on Account) |

#### Supported product IDs (hardcoded)
```apex
private static final Set<Id> SUPPORTED_PRODUCT_IDS = new Set<Id>{
    '01t4X000004U13iQAC', // Appointment Taker
    '01t4X000004U14AQAS', // Non-Appointment Taker
    '01t4X000004U148QAC'  // Marketer
};
```
Test fallback uses product names (`Appointment Taker`, `Non-Appointment Taker`, `Marketer`) to avoid hardcoded IDs in tests.

---

### Apex — Audit Loggers

#### AttendeeProcessingLogger

**Invocable label:** `Create Attendee Processing Log`
Creates one `Attendee_Processing_Log__c` record per Flow execution. Returns `processingLogId` for downstream steps.

**Key inputs:** `opportunityId` (required), `processingType`, `status`, `emailMessageId`, `senderEmail`, `senderName`, `flowApiName`
**Key outputs:** `processingLogId`, `processingLogName`, `success`, `errorMessage`

#### AttendeeProcessingLogUpdater

**Invocable label:** `Update Attendee Processing Log`
Updates an existing log record. Called 2–3 times per execution: after AI extraction (with `aiRawResponse`), after Apex assignment (with final counts/status), and on fault paths.

**Key inputs:** `processingLogId` (required), `status`, `attendeesProvided`, `attendeesAssigned`, `attendeesNotAssigned`, `openSlotsRemaining`, `aiRawResponse`, `errorMessage`, `errorCategory`

#### AttendeeAssignmentDetailLogger

**Invocable label:** `Log Attendee Assignment Detail`
Creates one `Attendee_Assignment_Detail__c` per OLI assignment attempt. Called internally by `ProcessAppointmentTakerAttendees` (not directly from Flow).

**Key inputs:** `processingLogId`, `opportunityProductId`, `productName`, `productType`, `eventName`, `extractedName`, `extractedEmail`, `assignedContactId`, `assignmentStatus` (`Assigned`/`Failed`/`Skipped`), `assignmentError`, `previousAttendeeName`, `previousAttendeeEmail`, `previousContactId`

---

## Object Schemas

### Opportunity (standard, key custom fields)

| Field API Name | Type | Purpose |
|---|---|---|
| `Signer_Contact__c` | Lookup(Contact) | Recipient of registration emails |
| `Sales_Territory__c` | Picklist (required) | Required by validation rule; set to `'North'` in tests |
| `External_Online_Order__c` | Checkbox | When true, Flow A does not fire |
| `RecordTypeId` | ID | Consumer/Meetings: `01230000000bVYmAAM` |

### OpportunityLineItem (standard, key custom fields)

| Field API Name | Type | Purpose |
|---|---|---|
| `Attendee_Name__c` | Text | Full name written by agent |
| `Attendee_First_Name__c` | Text | First name written by agent |
| `Attendee_Email__c` | Email/Text | Email written by agent |
| `Event_Attendee_Contact__c` | Lookup(Contact) | Resolved Contact on the Account |
| `Attendee_Phone_Number__c` | Text | Not used by agent |
| `Event_Name__c` | Text (required) | Used for group-fill matching |
| `Product_Type__c` | Text (required) | Used for group-fill matching |
| `Organization__c` | Picklist (required) | Required by validation rule |
| `Product_Year__c` | Picklist (required) | Required by validation rule |
| `Product_Category__c` | Picklist (required) | Must match `Product2.Opportunity_Product_Category__c` |

### EmailMessage (standard)

| Field | Purpose |
|---|---|
| `RelatedToId` | Polymorphic; links to Opportunity for Flow B trigger |
| `Incoming` | `true` for inbound; Flow B filters on this |
| `Subject` | Contains subject pattern + `[REG:OppId]` token |
| `TextBody` | Passed to GenAI prompt |
| `ReplyToEmailMessageId` | Links reply to original outgoing message |
| `FromAddress` / `FromName` | Logged to processing log |

### Attendee_Processing_Log__c (custom)

Auto-number format: `APL-{00000}`

| Field API Name | Type | Purpose |
|---|---|---|
| `Opportunity__c` | Lookup(Opportunity) | Parent opportunity |
| `Processing_Type__c` | Text | `Inbound Reply` or `Outbound Email` |
| `Status__c` | Picklist | `In Progress` / `Success` / `Partial Success` / `Failed` |
| `Processing_Date__c` | DateTime | Timestamp of log creation |
| `Email_Message_Id__c` | Text | Incoming EmailMessage ID |
| `Outgoing_Email_Id__c` | Text | Original outgoing EmailMessage ID |
| `Sender_Email__c` | Text | Reply sender email |
| `Sender_Name__c` | Text | Reply sender name |
| `AI_Prompt_Input__c` | LongText | (not currently populated) |
| `AI_Raw_Response__c` | LongText | Raw JSON from GenAI prompt |
| `AI_Model_Used__c` | Text | (not currently populated) |
| `Attendees_Provided__c` | Number | Count from JSON |
| `Attendees_Assigned__c` | Number | Successful DML updates |
| `Attendees_Not_Assigned__c` | Number | Failed/skipped |
| `Open_Slots_Remaining__c` | Number | Open OLI slots after run |
| `Total_Registration_Products__c` | Number | Total OLIs queried |
| `Error_Message__c` | LongText | Error detail or fault message |
| `Error_Category__c` | Text | Classification |
| `Flow_API_Name__c` | Text | Which flow ran |
| `Flow_Interview_GUID__c` | Text | (not currently populated) |

### Attendee_Assignment_Detail__c (custom)

Auto-number format: `AAD-{00000}`, `sharingModel: ControlledByParent`

| Field API Name | Type | Purpose |
|---|---|---|
| `Processing_Log__c` | Lookup(Attendee_Processing_Log__c) | Master-detail parent |
| `Opportunity_Product__c` | Lookup(OpportunityLineItem) | Target OLI |
| `Product_Name__c` | Text | Product name snapshot |
| `Product_Type__c` | Text | OLI product type |
| `Event_Name__c` | Text | OLI event name |
| `Extracted_Name__c` | Text | Name from AI |
| `Extracted_Email__c` | Email/Text | Email from AI |
| `Extracted_Phone__c` | Text | Phone from AI (not populated) |
| `Assigned_Contact__c` | Lookup(Contact) | Resolved contact |
| `Assignment_Status__c` | Picklist | `Assigned` / `Failed` / `Skipped` |
| `Assignment_Error__c` | LongText | DML error detail |
| `Previous_Attendee_Name__c` | Text | Pre-update snapshot |
| `Previous_Attendee_Email__c` | Text | Pre-update snapshot |
| `Previous_Contact__c` | Lookup(Contact) | Pre-update snapshot |

---

## Org-Specific IDs

These IDs are hardcoded in Flow A XML and `ProcessAppointmentTakerAttendees.cls`. They are specific to the `mac.kitchin@informa.com` org.

| Component | ID |
|---|---|
| Product2 "Appointment Taker" | `01t4X000004U13iQAC` |
| Product2 "Non-Appointment Taker" | `01t4X000004U14AQAS` |
| Product2 "Marketer" | `01t4X000004U148QAC` |
| Product2 RecordType (Appointment Taker) | `01230000000beHkAAI` |
| Opportunity RecordType "Consumer/Meetings" | `01230000000bVYmAAM` |
| Email Service address | `attendeereplyemailhandler@o-23lkusfw7mgqvhycorj7ar1qdafgul67ylcf51i6y4y6urhrg0.3-1h2naeac.usa594.apex.salesforce.com` |

**When replicating to a different org:** query for these IDs with `sf data query` and update the flow XML and Apex accordingly.

---

## Step-by-Step Replication Guide

### 1. Set up Salesforce CLI and authenticate
```bash
npm install -g @salesforce/cli
sf org login web --alias my-org --set-default
```

### 2. Clone the repo and verify project structure
```bash
git clone <repo-url>
cd attendee-info-agent
ls force-app/main/default/
# Expected: classes/ flows/ genAiPromptTemplates/ objects/ pages/ reportTypes/
```

### 3. Find your org's Product IDs
```bash
sf data query \
  --query "SELECT Id, Name FROM Product2 WHERE Name IN ('Appointment Taker','Non-Appointment Taker','Marketer')" \
  --target-org my-org
```
Update `SUPPORTED_PRODUCT_IDS` in `ProcessAppointmentTakerAttendees.cls` and the `<filters>` in `Appointment_Taker_Send_Registration_Emails.flow-meta.xml`.

### 4. Find your org's RecordType IDs (for test setup)
```bash
sf data query \
  --query "SELECT Id, Name, SObjectType FROM RecordType WHERE SObjectType IN ('Opportunity','Product2') AND IsActive = true" \
  --target-org my-org
```
Update the test classes if the RecordType IDs differ.

### 5. Deploy custom objects first
```bash
sf project deploy start \
  --source-dir force-app/main/default/objects \
  --target-org my-org
```

### 6. Deploy Apex classes
```bash
sf project deploy start \
  --source-dir force-app/main/default/classes \
  --target-org my-org \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest,AttendeeReplyEmailHandlerTest,AttendeeProcessingLoggerTest
```
All tests must pass before proceeding.

### 7. Deploy the GenAI Prompt Template
```bash
sf project deploy start \
  --source-dir force-app/main/default/genAiPromptTemplates/Extract_Attendee_Information.genAiPromptTemplate-meta.xml \
  --target-org my-org
```
After deploy, open Setup → Prompt Builder → `Extract Attendee Information` → verify Active version is v4 with `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku`.

### 8. Deploy flows
```bash
# Flow A
sf project deploy start \
  --source-dir "force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml" \
  --target-org my-org

# Flow B
sf project deploy start \
  --source-dir "force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml" \
  --target-org my-org
```
Activate both flows in Flow Builder after deployment (or set `<status>Active</status>` in XML before deploying).

### 9. Create Org-Wide Email Address
Setup → Organization-Wide Addresses → Add `attendeeinfo@informa.com` with display name `Connect Meetings Team`. Verify the email address.

### 10. Configure Email Service
1. Setup → Email Services → New
2. Name: `AttendeeReplyHandler`, Class: `AttendeeReplyEmailHandler`
3. Save and copy the generated email address

### 11. Configure email forwarding
In Exchange Admin Center (or equivalent), set up the `attendeeinfo@informa.com` mailbox to forward all inbound mail to the SF Email Service address from step 10.

### 12. End-to-end test
1. Create an Opportunity with Appointment Taker OLIs and a populated `Signer_Contact__c`
2. Set OLIs with `Attendee_Name__c = null`
3. Move Opportunity to Closed Won
4. Flow A fires → check Signer Contact's email for the follow-up request
5. Reply to the email with attendee names/emails in the blanks
6. Check `Attendee_Processing_Log__c` for a new record with `Status = Success`
7. Check the OLIs — `Attendee_Name__c` and `Attendee_Email__c` should be populated

---

## Known Gotchas

### Flow XML
- `processType` must be `AutoLaunchedFlow` for record-triggered flows — not `Flow` or `RecordTriggered`
- Trigger config lives in the `<start>` element, not in `<recordTriggers>`
- Cross-object field filters in `<recordLookups>` (e.g., `Product2.Name`) cause `null__NotFound` errors — use `Product2Id` (the direct ID field) instead
- GenAI prompt action type is `generatePromptResponse` (not `apex`, `generateText`, or `promptTemplate`)
- GenAI prompt input parameter name must be `Input:EmailMessage` (with the `Input:` prefix exactly as defined in the template)
- `<storeOutputAutomatically>true</storeOutputAutomatically>` is required to access `promptResponse` output
- Every element needs explicit `<connector>` to the next element; orphaned elements won't deploy

### Apex test classes
- Standard Pricebook: use `Test.getStandardPricebookId()` — never query `WHERE Pricebook2.IsStandard = true`
- DLRS triggers on OLI fire AfterInsert/AfterUpdate and update parent Opportunity — parent must have `Sales_Territory__c` populated
- Validation rule on OLI `Product_Category__c` cross-checks against `Product2.Opportunity_Product_Category__c` — both must match
- Picklist values are record-type-specific; wrong record type → validation failure at test insert
- USER_MODE DML fails if the SObject instance has relationship fields populated (e.g. `Product2.Name`) — create clean instances with `Id` + target fields only

### Security model
- OLI SOQL uses `WITH USER_MODE` (read security enforced)
- OLI DML uses `AccessLevel.SYSTEM_MODE` (write access to custom fields that may not have FLS for the running user)
- `AttendeeProcessingLogger` and `AttendeeAssignmentDetailLogger` use `with sharing` — ensure the running user has access to those objects

### GenAI / prompt
- `GenAiPromptTemplate` is not SOQL-queryable — always use `sf project retrieve start --metadata GenAiPromptTemplate:...`
- Prompt version upgrades create a new version in org but do not automatically activate it — must manually activate or re-deploy with the updated `<activeVersionIdentifier>`
- The active version identifier in the XML is a hash (`ZIlRtZe/...`), not a human-readable version number

### Email routing
- The `[REG:OppId]` token in the outgoing email subject is critical for deterministic reply routing — do not change the subject template without updating `AttendeeReplyEmailHandler.REG_TOKEN_PATTERN`
- The legacy fallback (60-day lookback by subject + sender) only works if there is exactly one matching outgoing email per sender in that window
- Outlook's reply separator is 32 underscores — the handler strips quoted content below it to prevent the AI from re-processing the original template text
