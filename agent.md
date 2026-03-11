# Attendee Info Agent — Build Documentation

Everything used to build the Agentforce Appointment Taker Registration Agent: MCP tools, Salesforce API calls, object schemas, authentication setup, and step-by-step replication instructions.

**Target org:** `mac.kitchin@informa.com` (alias: `Connect Meetings`)
**First live test passed:** 2026-02-19
**Salesforce API version:** 65.0

---

## Table of Contents

1. [What This Agent Does](#1-what-this-agent-does)
2. [MCP Server](#2-mcp-server)
3. [Authentication Setup](#3-authentication-setup)
4. [Salesforce Object Schemas](#4-salesforce-object-schemas)
5. [Salesforce API Calls Made](#5-salesforce-api-calls-made)
6. [Components Built](#6-components-built)
7. [AI / GenAI Configuration](#7-ai--genai-configuration)
8. [Email Routing Architecture](#8-email-routing-architecture)
9. [Step-by-Step: How to Replicate](#9-step-by-step-how-to-replicate)
10. [Deployment Commands](#10-deployment-commands)
11. [Org-Specific IDs (Must Update Per Org)](#11-org-specific-ids-must-update-per-org)
12. [Key Gotchas](#12-key-gotchas)

---

## 1. What This Agent Does

Automates Appointment Taker attendee registration on "Connect Meetings" opportunities:

1. Opportunity moves to **Closed Won** with Appointment Taker / Non-Appointment Taker / Marketer products on it
2. If any OpportunityLineItems are missing attendee names/emails → Flow A sends a follow-up email to the Signer Contact
3. Signer replies with attendee details
4. Apex email handler routes the reply to the correct Opportunity → inserts an inbound EmailMessage
5. Flow B triggers on the new EmailMessage → calls a GenAI prompt (Claude 4.5 Haiku) to extract attendee data as JSON
6. Invocable Apex writes the extracted names/emails to the matching OLI fields
7. Audit logs are created at every step (`Attendee_Processing_Log__c` + `Attendee_Assignment_Detail__c`)
8. Notification emails are sent to the admin (`mac.kitchin@informa.com`) with success/failure status

---

## 2. MCP Server

**Salesforce MCP server ID:** `2cb05261-a470-48a3-a27b-2a1a01707c95`

### MCP Tools Used

| Tool | Purpose |
|------|---------|
| `salesforce_query_records` | Run SOQL queries against the org (Opportunities, OLIs, Contacts, EmailMessages) |
| `salesforce_describe_object` | Inspect field metadata for standard and custom objects |
| `salesforce_aggregate_query` | Run aggregate SOQL (COUNT, GROUP BY) for auditing and validation |

### Key Queries Run During Build

```soql
-- Find existing Appointment Taker opportunities
SELECT Id, Name, StageName, Sales_Territory__c, Signer_Contact__c
FROM Opportunity
WHERE Id IN (
  SELECT OpportunityId FROM OpportunityLineItem
  WHERE Product2Id = '01t4X000004U13iQAC'
)
LIMIT 5

-- Inspect OLI custom fields
DESCRIBE OpportunityLineItem

-- Check outgoing email messages linked to opportunities
SELECT Id, Subject, ToAddress, RelatedToId, CreatedDate
FROM EmailMessage
WHERE Incoming = FALSE
AND RelatedToId != NULL
AND Subject LIKE 'Action Required: Attendee Details%'
ORDER BY CreatedDate DESC
LIMIT 10

-- Check audit logs
SELECT Id, Name, Status__c, Processing_Date__c, Attendees_Assigned__c, Error_Category__c
FROM Attendee_Processing_Log__c
ORDER BY Processing_Date__c DESC
LIMIT 20
```

> **Note:** `GenAiPromptTemplate` is **not** queryable via SOQL. Use `sf project retrieve start --metadata GenAiPromptTemplate` instead.

---

## 3. Authentication Setup

### Salesforce Org Connection (SFDX)

The project connects to the org via SFDX. Credentials are stored locally in `.sf/` (excluded from git via `.gitignore`).

```bash
# Authenticate to org (run once per machine)
sf org login web --alias "Connect Meetings" --instance-url https://login.salesforce.com

# Verify connection
sf org display --target-org mac.kitchin@informa.com
```

No credentials are committed to the repository. The `.sf/` directory holds the OAuth token locally.

### Org-Wide Email Address

- **Address:** `attendeeinfo@informa.com`
- **Purpose:** All outbound registration request emails are sent from this address
- **Setup:** Configured in Salesforce Setup → Email → Organization-Wide Addresses
- **Required step:** The address must be verified (Salesforce sends a confirmation email)

### Exchange Forwarding

- **Exchange mailbox:** `attendeeinfo@informa.com`
- **Forwards to:** Salesforce Email Service address (see [Email Routing Architecture](#8-email-routing-architecture))
- **Configured in:** Microsoft Exchange Admin Center (not in Salesforce)

### Salesforce Email Service

- **Email Service name:** `AttendeeReplyHandler`
- **Apex class:** `AttendeeReplyEmailHandler`
- **Generated SF address:** `attendeereplyemailhandler@o-23lkusfw7mgqvhycorj7ar1qdafgul67ylcf51i6y4y6urhrg0.3-1h2naeac.usa594.apex.salesforce.com`
- **Setup:** Salesforce Setup → Email → Email Services → New

---

## 4. Salesforce Object Schemas

### Standard Objects Used

#### Opportunity

| Field | Type | Notes |
|-------|------|-------|
| `Id` | ID | |
| `Name` | Text | |
| `StageName` | Picklist | Flow A triggers when = `Closed Won` |
| `AccountId` | Lookup(Account) | Used for Contact matching |
| `Signer_Contact__c` | Lookup(Contact) | Recipient of registration emails; required for Flow A |
| `External_Online_Order__c` | Checkbox | Flow A skips if `true` |
| `Sales_Territory__c` | Picklist | Required by validation rules; affects OLI inserts via DLRS |
| `RecordTypeId` | ID | Consumer/Meetings: `01230000000bVYmAAM` |

#### OpportunityLineItem

| Field | Type | Notes |
|-------|------|-------|
| `Id` | ID | |
| `OpportunityId` | Lookup(Opportunity) | |
| `Product2Id` | Lookup(Product2) | Filtered to 3 supported product IDs |
| `Attendee_Name__c` | Text | Full name — written by agent |
| `Attendee_First_Name__c` | Text | First name — written by agent |
| `Attendee_Email__c` | Email | Email — written by agent |
| `Attendee_Phone_Number__c` | Phone | Not used by agent |
| `Event_Attendee_Contact__c` | Lookup(Contact) | Resolved Contact — written by agent |
| `Event_Name__c` | Text | Required by validation rule |
| `Product_Type__c` | Text | Required by validation rule |
| `Organization__c` | Text | Required by validation rule |
| `Product_Year__c` | Text | Required by validation rule |
| `Product_Category__c` | Text | Required by validation rule |

#### EmailMessage

| Field | Type | Notes |
|-------|------|-------|
| `Id` | ID | |
| `RelatedToId` | Polymorphic | Set to Opportunity ID; triggers Flow B |
| `Incoming` | Boolean | `true` for inbound replies |
| `Subject` | Text | Used by Flow B entry filter and Apex routing |
| `TextBody` | Text | Passed to AI prompt; sanitized first |
| `ToAddress` | Text | Original recipient (used for routing match) |
| `ReplyToEmailMessageId` | Lookup | Links reply to original outgoing email |

#### Contact

| Field | Type | Notes |
|-------|------|-------|
| `Id` | ID | |
| `Email` | Email | Matched against extracted attendee email |
| `AccountId` | Lookup(Account) | Scoped to Opportunity's account |

#### Product2

| Field | Type | Notes |
|-------|------|-------|
| `Id` | ID | |
| `Name` | Text | |
| `RecordTypeId` | ID | Required: `01230000000beHkAAI` |
| `Opportunity_Product_Category__c` | Text | Required: `Event` (validation rule) |

---

### Custom Objects Built

#### `Attendee_Processing_Log__c` — Parent Audit Record

Auto-number: `APL-{00000}` (e.g., APL-00001)

| Field API Name | Type | Description |
|---------------|------|-------------|
| `Opportunity__c` | Lookup(Opportunity) | Related opportunity |
| `Processing_Type__c` | Picklist | `Inbound Reply` / `Outbound Email` / `Manual Reprocess` |
| `Status__c` | Picklist | `In Progress` → `Success` / `Partial Success` / `Failed` |
| `Processing_Date__c` | DateTime | Timestamp when processing started |
| `Email_Message_Id__c` | Text | Inbound EmailMessage ID |
| `Outgoing_Email_Id__c` | Text | Original outgoing EmailMessage ID |
| `Sender_Email__c` | Email | Reply sender's email address |
| `Sender_Name__c` | Text | Reply sender's display name |
| `Total_Registration_Products__c` | Number | Count of supported OLIs on opportunity |
| `Attendees_Provided__c` | Number | Count of attendees extracted by AI |
| `Attendees_Assigned__c` | Number | Count successfully written to OLIs |
| `Attendees_Not_Assigned__c` | Number | Count that could not be assigned |
| `Open_Slots_Remaining__c` | Number | Empty OLI slots after assignment |
| `AI_Prompt_Input__c` | LongTextArea | Email body sent to the prompt (sanitized) |
| `AI_Raw_Response__c` | LongTextArea | Raw JSON string returned by AI |
| `AI_Model_Used__c` | Text | Model identifier (e.g., `Claude 4.5 Haiku`) |
| `Error_Message__c` | LongTextArea | Error detail if processing failed |
| `Error_Category__c` | Picklist | `None` / `JSON Parse` / `AI Extraction` / `Validation` / `DML` / `Other` / `Flow Error` |
| `Flow_API_Name__c` | Text | Name of the triggering flow |
| `Flow_Interview_GUID__c` | Text | Flow interview identifier |

#### `Attendee_Assignment_Detail__c` — Child Audit Record (one per OLI attempt)

Auto-number: `AAD-{00000}` (e.g., AAD-00001)

| Field API Name | Type | Description |
|---------------|------|-------------|
| `Processing_Log__c` | Lookup(Attendee_Processing_Log__c) | Parent log |
| `Opportunity_Product__c` | Lookup(OpportunityLineItem) | Target OLI |
| `Product_Name__c` | Text | OLI product name |
| `Product_Type__c` | Text | OLI product type |
| `Event_Name__c` | Text | OLI event name |
| `Extracted_Name__c` | Text | Name extracted by AI |
| `Extracted_Email__c` | Email | Email extracted by AI |
| `Assigned_Contact__c` | Lookup(Contact) | Matched Contact record |
| `Assignment_Status__c` | Picklist | `Assigned` / `Failed` / `Skipped` |
| `Assignment_Error__c` | Text | Error message if assignment failed |
| `Previous_Attendee_Name__c` | Text | Name before update (audit trail) |
| `Previous_Attendee_Email__c` | Email | Email before update (audit trail) |
| `Previous_Contact__c` | Lookup(Contact) | Contact before update (audit trail) |

---

## 5. Salesforce API Calls Made

All calls go through SFDX CLI or the Salesforce MCP server (no direct REST API calls in code — everything is SOQL/DML/Flow/Apex).

### SOQL Queries in Apex

**`ProcessAppointmentTakerAttendees.cls`**

```apex
// Load open OLI slots for the 3 supported product types
SELECT Id, Product2Id, Product2.Name, Event_Name__c, Product_Type__c,
       Attendee_Name__c, Attendee_Email__c, Event_Attendee_Contact__c, CreatedDate
FROM OpportunityLineItem
WHERE OpportunityId = :opportunityId
  AND Product2Id IN :SUPPORTED_PRODUCT_IDS
  AND Attendee_Name__c = NULL
  AND Attendee_Email__c = NULL
WITH USER_MODE
ORDER BY CreatedDate ASC

// Resolve Account for the Opportunity (to scope Contact search)
SELECT AccountId FROM Opportunity
WHERE Id = :opportunityId
WITH USER_MODE

// Bulk-resolve Contacts by email within the Account
SELECT Id, Email FROM Contact
WHERE Email IN :attendeeEmails
  AND AccountId = :accountId
WITH USER_MODE
```

**`AttendeeReplyEmailHandler.cls`**

```apex
// Token-based routing: find original outgoing email by [REG:OppId] token + sender match
SELECT Id, ToAddress
FROM EmailMessage
WHERE Incoming = FALSE
  AND RelatedToId = :opportunityId
  AND Subject LIKE :('%[REG:' + Id + ']%')

// Legacy fallback (60-day lookback, no token)
SELECT Id, RelatedToId, ToAddress
FROM EmailMessage
WHERE Incoming = FALSE
  AND RelatedToId != NULL
  AND Subject LIKE :subjectPrefix
  AND CreatedDate >= :cutoff
```

### Supported Product IDs (hardcoded in Apex)

```apex
private static final Set<Id> SUPPORTED_PRODUCT_IDS = new Set<Id>{
    '01t4X000004U13iQAC',  // Appointment Taker
    '01t4X000004U14AQAS',  // Non-Appointment Taker
    '01t4X000004U148QAC'   // Marketer
};
```

### DML Operations

| Operation | Object | Access Level | Reason |
|-----------|--------|-------------|--------|
| `SELECT` | OLI, Opportunity, Contact | `WITH USER_MODE` | Enforces FLS for running user |
| `UPDATE` | OpportunityLineItem | `SYSTEM_MODE` | Automated process user lacks FLS on custom fields |
| `INSERT` | Attendee_Processing_Log__c | `SYSTEM_MODE` | Audit log — process user context |
| `INSERT` | Attendee_Assignment_Detail__c | `SYSTEM_MODE` | Audit log — process user context |
| `INSERT` | EmailMessage | `SYSTEM_MODE` | Email handler linking reply to opportunity |

---

## 6. Components Built

### Apex Classes

| Class | Type | Purpose |
|-------|------|---------|
| `ProcessAppointmentTakerAttendees` | Invocable | Parses AI JSON, matches attendees to OLI slots, writes fields, logs details |
| `AttendeeReplyEmailHandler` | Email Service (InboundEmailHandler) | Routes inbound email replies to the correct Opportunity |
| `AttendeeProcessingLogger` | Invocable | Creates `Attendee_Processing_Log__c` records |
| `AttendeeProcessingLogUpdater` | Invocable | Updates existing processing log records |
| `AttendeeAssignmentDetailLogger` | Invocable | Creates `Attendee_Assignment_Detail__c` records |

**Test Classes:** `ProcessAppointmentTakerAttendeesTest` (7/7 passing), `AttendeeReplyEmailHandlerTest` (4/4 passing), `AttendeeProcessingLoggerTest`

### Flows

#### Flow A: `Appointment_Taker_Send_Registration_Emails`

- **Type:** Record-Triggered, After Update on Opportunity
- **Entry conditions:** `StageName = Closed Won` AND `Signer_Contact__c IS NOT NULL` AND `External_Online_Order__c = false`
- **Logic:** Queries OLIs for 3 supported products → counts missing attendee slots → sends follow-up email (or confirmation if complete)
- **Email subject:** `Action Required: Attendee Details for your Event Registrations [REG:{OpportunityId}]`
- **Sender:** `attendeeinfo@informa.com` (Org-Wide Email Address)

#### Flow B: `Event_Registration_Process_Attendee_Reply`

- **Type:** Record-Triggered, After Create on EmailMessage
- **Entry conditions:** `Incoming = true` AND `Subject CONTAINS 'Action Required: Attendee Details for your Event Registrations'`
- **Logic:**
  1. Create audit log (In Progress)
  2. Call GenAI prompt → extract attendee JSON
  3. Update audit log with AI response
  4. Call `ProcessAppointmentTakerAttendees` → assign attendees to OLIs
  5. Decision: success/failure → update audit log → send notification email to admin
  6. Fault handler: captures `$Flow.FaultMessage` → logs as "Flow Error" → sends failure notification

### GenAI Prompt Templates

| Template | Model | Status | Purpose |
|----------|-------|--------|---------|
| `Extract_Attendee_Information` | Claude 4.5 Haiku (Bedrock) | Active (v4) | Extract attendee JSON from inbound email body |
| `Opportunity_Creation` | GPT-5 | Draft | Future: create Opportunity from unstructured text |

### Custom Objects

- `Attendee_Processing_Log__c` — parent audit record per processing run
- `Attendee_Assignment_Detail__c` — child record per OLI assignment attempt

### Report Type

- `Attendee_Processing_with_Details` — joins logs to assignment details (outer join)

### List Views (on `Attendee_Processing_Log__c`)

- All Processing Logs
- Failed Processing Runs (`Status__c = Failed`)
- Inbound Reply Logs
- Outbound Email Logs
- Today's Processing Activity

---

## 7. AI / GenAI Configuration

### Prompt Template: `Extract_Attendee_Information` (v4 — Active)

**Model:** `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku` (Claude 4.5 Haiku via AWS Bedrock)
**Template type:** `einstein_gpt__flex`
**Input SObject:** `EmailMessage` (fields: `Subject`, `TextBody`)

**Invocation in Flow (action call):**

```xml
<actionCalls>
  <name>Extract_Attendee_Information</name>
  <actionName>Extract_Attendee_Information</actionName>
  <actionType>generatePromptResponse</actionType>
  <inputParameters>
    <name>Input:EmailMessage</name>
    <value><elementReference>$Record</elementReference></value>
  </inputParameters>
  <outputParameters>
    <assignToReference>varAIResponse</assignToReference>
    <name>promptResponse</name>
  </outputParameters>
</actionCalls>
```

> **Critical:** `actionType` must be `generatePromptResponse`. The input parameter name requires the `Input:` prefix.

**Prompt behavior:** Handles two email formats:

1. **Structured template replies** (from the registration email template):
   ```
   Event: <event_name> | Type: <product_type>
   Attendee Name: <first_name> <last_name>
   Attendee Email: <email>
   ```

2. **Freeform replies:** Extracts names and emails, leaves event/product fields empty

**Expected output (raw JSON, no markdown, no backticks):**

```json
[
  {
    "event_name": "BizBash MEGA",
    "product_type": "Association",
    "first_name": "Jane",
    "last_name": "Doe",
    "email": "jane@company.com"
  }
]
```

### Attendee Assignment Strategy

```
For each extracted attendee:
  1. Group-fill match: event_name + product_type → fill matching OLI slot
  2. Positional fallback: next available unclaimed slot (ordered by CreatedDate ASC)
  3. Contact resolution: match email → Contact on same Account
  4. Write: Attendee_Name__c, Attendee_First_Name__c, Attendee_Email__c, Event_Attendee_Contact__c
```

**Result statuses:**
- `Success` — all attendees assigned
- `Partial Success` — some assigned, some skipped/failed
- `Failed` — no assignments or processing error

---

## 8. Email Routing Architecture

```
Signer replies to attendeeinfo@informa.com
         │
         ▼
Exchange mailbox (attendeeinfo@informa.com)
         │ forwards all inbound mail
         ▼
Salesforce Email Service (AttendeeReplyHandler)
         │ calls
         ▼
AttendeeReplyEmailHandler.cls
         │
         ├─ Extract [REG:OppId] from subject (token-based routing)
         │   └─ Validate sender email/domain matches original recipient
         │
         ├─ Fallback: search last 60 days of outgoing emails by sender match
         │
         ├─ Sanitize email body:
         │   - Strip Outlook quoted reply separator (________________________________)
         │   - Decode HTML entities (&amp; → &, &#124; → |)
         │   - Cap at 28,000 characters
         │
         └─ INSERT EmailMessage with RelatedToId = OpportunityId
                  │
                  ▼ (triggers Flow B)
         Event_Registration_Process_Attendee_Reply
```

**Routing priority:**
1. Token-based: `[REG:OppId]` in subject → deterministic, zero ambiguity
2. Legacy fallback: 60-day lookback by sender address (handles emails without token)
3. Domain-level matching: colleagues from same domain can reply on behalf of original recipient

**Why Apex Email Service (not Email-to-Case):**
- Email-to-Case creates unwanted Case records and sets `RelatedToId` → Case, not Opportunity
- Apex Email Service gives full control: insert the EmailMessage linked to the correct Opportunity, triggering Flow B directly

---

## 9. Step-by-Step: How to Replicate

### Prerequisites

- Salesforce CLI (`sf`) installed
- Node.js 18+ installed (for dev tooling)
- Authenticated Salesforce org with:
  - API version 65.0+
  - Einstein/GenAI features enabled (for prompt templates)
  - Bedrock integration configured (for Claude 4.5 Haiku)

### Step 1: Clone and Install

```bash
git clone <repo-url>
cd attendee-info-agent
npm install

# Authenticate to your Salesforce org
sf org login web --alias myorg --instance-url https://login.salesforce.com
```

### Step 2: Update Org-Specific IDs

Before deploying, update the hardcoded IDs to match your org:

**`force-app/main/default/classes/ProcessAppointmentTakerAttendees.cls` (line ~96-100):**

```apex
private static final Set<Id> SUPPORTED_PRODUCT_IDS = new Set<Id>{
    'YOUR_APPOINTMENT_TAKER_PRODUCT2_ID',
    'YOUR_NON_APPOINTMENT_TAKER_PRODUCT2_ID',
    'YOUR_MARKETER_PRODUCT2_ID'
};
```

**`force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`:**
Update the `<value>` filters for `Product2Id` in the Get Records element.

**Test classes:** Update `RecordTypeId` values for Product2 and Opportunity.

To find your org's IDs:

```bash
# Find your Product2 IDs
sf data query --query "SELECT Id, Name FROM Product2 WHERE Name IN ('Appointment Taker', 'Non-Appointment Taker', 'Marketer')" --target-org myorg

# Find your Opportunity RecordType ID
sf data query --query "SELECT Id, Name FROM RecordType WHERE SObjectType = 'Opportunity' AND Name = 'Consumer/Meetings'" --target-org myorg

# Find your Product2 RecordType ID
sf data query --query "SELECT Id, Name FROM RecordType WHERE SObjectType = 'Product2'" --target-org myorg
```

### Step 3: Deploy Custom Objects First

```bash
sf project deploy start \
  --metadata CustomObject:Attendee_Processing_Log__c \
  --metadata CustomObject:Attendee_Assignment_Detail__c \
  --metadata ReportType:Attendee_Processing_with_Details \
  --target-org myorg
```

### Step 4: Deploy Apex Classes with Tests

```bash
sf project deploy start \
  --metadata ApexClass:AttendeeProcessingLogger \
  --metadata ApexClass:AttendeeProcessingLogUpdater \
  --metadata ApexClass:AttendeeAssignmentDetailLogger \
  --metadata ApexClass:ProcessAppointmentTakerAttendees \
  --metadata ApexClass:ProcessAppointmentTakerAttendeesTest \
  --metadata ApexClass:AttendeeReplyEmailHandler \
  --metadata ApexClass:AttendeeReplyEmailHandlerTest \
  --metadata ApexClass:AttendeeProcessingLoggerTest \
  --target-org myorg \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest,AttendeeReplyEmailHandlerTest,AttendeeProcessingLoggerTest
```

All tests must pass before proceeding.

### Step 5: Deploy the GenAI Prompt Template

```bash
sf project deploy start \
  --metadata GenAiPromptTemplate:Extract_Attendee_Information \
  --target-org myorg
```

Verify in Setup → Einstein → Prompt Builder that the template is published.

### Step 6: Deploy and Activate Flow A (Outbound)

```bash
sf project deploy start \
  --metadata Flow:Appointment_Taker_Send_Registration_Emails \
  --target-org myorg
```

Then in Salesforce Setup → Flows, open the flow and verify:
- Sender type is set to **Org-Wide Email Address**
- Sender address is `attendeeinfo@informa.com` (or your address)
- Email body template matches your registration format

### Step 7: Set Up Org-Wide Email Address

1. Setup → Email → Organization-Wide Addresses → Add
2. Email: `attendeeinfo@informa.com`
3. Display name: e.g., `Informa Connect Meetings`
4. Click **Save** → check the inbox and click the verification link Salesforce sends

### Step 8: Set Up Email Service

1. Setup → Email → Email Services → New Email Service
2. Name: `AttendeeReplyHandler`
3. Apex Class: `AttendeeReplyEmailHandler`
4. Accept Email From: (leave blank to accept all, or restrict to your domain)
5. Save → copy the generated Email Service Address
6. Under the service, click **New Email Address** to get the routing address

### Step 9: Configure Exchange Forwarding

In Microsoft Exchange Admin Center:
1. Find the `attendeeinfo@informa.com` mailbox
2. Add a forwarding rule to redirect all inbound mail to the Salesforce Email Service address from Step 8
3. Optionally keep a copy in the mailbox for auditing

### Step 10: Deploy and Activate Flow B (Inbound)

```bash
sf project deploy start \
  --metadata Flow:Event_Registration_Process_Attendee_Reply \
  --target-org myorg
```

Then activate it:

```bash
sf project deploy start \
  --metadata FlowDefinition:Event_Registration_Process_Attendee_Reply \
  --target-org myorg
```

Or activate manually in Salesforce Setup → Flows.

### Step 11: End-to-End Test

1. Find a "Consumer/Meetings" Opportunity with Appointment Taker OLIs that have no attendee names/emails and a `Signer_Contact__c` set
2. Set `StageName` to `Closed Won`
3. Check that the registration request email arrives at the Signer Contact's email
4. Reply with attendee details in the template format
5. Check Salesforce:
   - `Attendee_Processing_Log__c` should have a new record with `Status__c = Success`
   - OLI `Attendee_Name__c` and `Attendee_Email__c` should be populated
   - Admin notification email should arrive at `mac.kitchin@informa.com`

---

## 10. Deployment Commands

### Deploy everything (full deploy)

```bash
sf project deploy start \
  --metadata CustomObject:Attendee_Processing_Log__c \
  --metadata CustomObject:Attendee_Assignment_Detail__c \
  --metadata ReportType:Attendee_Processing_with_Details \
  --metadata ApexClass:AttendeeProcessingLogger \
  --metadata ApexClass:AttendeeProcessingLogUpdater \
  --metadata ApexClass:AttendeeAssignmentDetailLogger \
  --metadata ApexClass:ProcessAppointmentTakerAttendees \
  --metadata ApexClass:ProcessAppointmentTakerAttendeesTest \
  --metadata ApexClass:AttendeeReplyEmailHandler \
  --metadata ApexClass:AttendeeReplyEmailHandlerTest \
  --metadata ApexClass:AttendeeProcessingLoggerTest \
  --metadata GenAiPromptTemplate:Extract_Attendee_Information \
  --metadata Flow:Appointment_Taker_Send_Registration_Emails \
  --metadata Flow:Event_Registration_Process_Attendee_Reply \
  --target-org myorg \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest,AttendeeReplyEmailHandlerTest,AttendeeProcessingLoggerTest
```

### Retrieve org changes back to local

```bash
# Sync a flow after making changes in Flow Builder UI
sf project retrieve start \
  --metadata "Flow:Appointment_Taker_Send_Registration_Emails" \
  --target-org mac.kitchin@informa.com

# Retrieve all prompt templates
sf project retrieve start \
  --metadata "GenAiPromptTemplate" \
  --target-org mac.kitchin@informa.com
```

### Useful audit queries

```bash
# Check recent processing logs
sf data query \
  --query "SELECT Name, Status__c, Processing_Date__c, Attendees_Assigned__c, Error_Category__c FROM Attendee_Processing_Log__c ORDER BY Processing_Date__c DESC LIMIT 20" \
  --target-org mac.kitchin@informa.com

# Check assignment details for a specific log
sf data query \
  --query "SELECT Name, Extracted_Name__c, Extracted_Email__c, Assignment_Status__c, Assignment_Error__c FROM Attendee_Assignment_Detail__c WHERE Processing_Log__c = 'YOUR_LOG_ID'" \
  --target-org mac.kitchin@informa.com
```

---

## 11. Org-Specific IDs (Must Update Per Org)

These IDs are hardcoded and **must be updated** when deploying to a new org:

| ID | What It Is | Where Used |
|----|-----------|-----------|
| `01t4X000004U13iQAC` | Product2: Appointment Taker | `ProcessAppointmentTakerAttendees.cls`, Flow A XML |
| `01t4X000004U14AQAS` | Product2: Non-Appointment Taker | Same |
| `01t4X000004U148QAC` | Product2: Marketer | Same |
| `01230000000bVYmAAM` | Opportunity RecordType: Consumer/Meetings | Test classes |
| `01230000000beHkAAI` | Product2 RecordType | Test classes |

---

## 12. Key Gotchas

### Flow Metadata XML

- `processType` must be `AutoLaunchedFlow` for record-triggered flows (not `Flow`)
- Trigger config goes in the `<start>` element — there is no `<recordTriggers>` element
- Use dedicated element tags: `<recordLookups>`, `<loops>`, `<assignments>`, `<decisions>`, `<actionCalls>` — not generic `<elements>`
- Cross-object field filters in `<recordLookups>` **do not work** (e.g., filtering on `Product2.Name` throws `null__NotFound`). Use the Product2 ID instead.
- GenAI prompt action: `actionType` must be `generatePromptResponse`; input parameter name must have `Input:` prefix (e.g., `Input:EmailMessage`)
- Each element needs explicit `<connector>` tags; each `<value>` needs a typed wrapper (`<stringValue>`, `<elementReference>`, etc.)

### Apex Test Classes

- Standard Pricebook: use `Test.getStandardPricebookId()` — never query by `IsStandard = true`
- DLRS trigger fires on OLI insert/update and updates the parent Opportunity → parent must have `Sales_Territory__c` set
- Product_Category validation rule cross-checks OLI `Product_Category__c` against `Product2.Opportunity_Product_Category__c`
- `Sales_Territory__c` picklist values are record-type-specific — check which values are valid for your RecordType
- USER_MODE DML fails if the SObject has queried relationship fields populated — always create clean instances with only `Id` + target fields before updating

### Security Model

- SOQL reads use `WITH USER_MODE` to enforce FLS for the running user
- DML writes use `AccessLevel.SYSTEM_MODE` because the automated process user lacks FLS on the custom attendee fields
- This combination is intentional: reads are safe/governed; writes succeed without granting broad permissions to the process user

### Email Routing

- `GenAiPromptTemplate` is not queryable via SOQL — use `sf project retrieve` to inspect/sync
- Email-to-Case was explicitly rejected: it creates Case records and sets `RelatedToId` to the Case, not the Opportunity
- The `[REG:OppId]` token in outbound email subjects enables deterministic reply routing without fuzzy matching

### Prompt Template

- Template type must be `einstein_gpt__flex`
- The model string for Claude 4.5 Haiku via Bedrock is `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku`
- The prompt must instruct the model to output raw JSON with no markdown fencing — Flow B passes the string directly to JSON.deserialize
- Prompt is capped at 28,000 characters of email body to stay within model context limits
