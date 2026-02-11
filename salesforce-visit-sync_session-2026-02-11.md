# Agentforce Appointment Taker Registration Agent — Session Memory
**Last updated:** 2026-02-11
**Project path:** `/Users/william.kitchin/OneDrive - Informa plc/Salesforce (Agentforce)/attendee-info-agent/`
**Target org:** `mac.kitchin@informa.com` (alias: `Connect Meetings`)
**Deploy command pattern:** `sf project deploy start --source-dir <path> --target-org mac.kitchin@informa.com`

---

## 1. Project Goal
Build an Agentforce-driven agent that automates Appointment Taker attendee registration via email:
1. Opportunity moves to **Closed Won** with "Appointment Taker" products
2. If attendee info is missing on OLIs → send follow-up email to Signer Contact
3. Signer replies with attendee names/emails
4. AI extracts attendee data from reply → Apex writes it to OpportunityLineItems

Reference manual: `/Users/william.kitchin/Downloads/Agentforce_Connect_Meetings_Event_Registration_Agent_Build_Manual.docx`

---

## 2. Org Schema (Key Fields)

### Opportunity
- `Signer_Contact__c` — Lookup(Contact), the person who receives registration emails
- `RecordTypeId: 01230000000bVYmAAM` — "Consumer/Meetings" (used by Appointment Taker opps)
- `Sales_Territory__c` — Required picklist (validation rule on OLI insert via DLRS trigger)

### OpportunityLineItem
- `Attendee_Name__c` — Full name (text)
- `Attendee_First_Name__c` — First name (text)
- `Attendee_Email__c` — Email (text)
- `Attendee_Phone_Number__c` — Phone (text, not used by agent)
- `Organization__c`, `Product_Year__c`, `Product_Category__c`, `Product_Type__c`, `Event_Name__c` — All required by validation rules

### Product2 ("Appointment Taker")
- **Id:** `01t4X000004U13iQAC`
- **RecordTypeId:** `01230000000beHkAAI`
- `Opportunity_Product_Category__c = 'Event'`

### EmailMessage
- `RelatedToId` — polymorphic lookup; when linked to Opportunity, Flow B uses this to pass the Opp ID to Apex
- `IsIncoming` — Boolean; Flow B filters on `true`
- `Subject`, `TextBody` — used by prompt template

---

## 3. Deployed Components — Status

### Phase 1: Apex Classes ✅ DEPLOYED & PASSING
**Files:**
- `force-app/main/default/classes/ProcessAppointmentTakerAttendees.cls` (227 lines)
- `force-app/main/default/classes/ProcessAppointmentTakerAttendees.cls-meta.xml`
- `force-app/main/default/classes/ProcessAppointmentTakerAttendeesTest.cls` (290 lines)
- `force-app/main/default/classes/ProcessAppointmentTakerAttendeesTest.cls-meta.xml`

**Invocable method:** `Process Appointment Taker Attendees`
- **Inputs:** `jsonString` (String), `opportunityId` (String)
- **Outputs:** `isSuccess` (Boolean), `statusMessage` (String)
- **JSON format expected:** `[{"first_name":"Jane","last_name":"Doe","email":"jane@co.com"}, ...]`
- **7/7 tests passing**

**Key implementation details:**
- Uses `WITH USER_MODE` on SOQL queries
- Uses `Database.update(toUpdate, false, AccessLevel.USER_MODE)` for DML
- Builds clean SObject instances (Id + target fields only) to avoid FLS errors on relationship fields in USER_MODE
- Assigns attendees to earliest-created open OLI slots (ordered by CreatedDate ASC)

**Test class validation rule workarounds (critical for future test changes):**
- Product2 requires: `Opportunity_Product_Category__c = 'Event'`, `RecordTypeId = '01230000000beHkAAI'`
- Opportunity requires: `RecordTypeId = '01230000000bVYmAAM'`, `Sales_Territory__c = 'North'`
- OLI requires: `Organization__c = 'BizBash'`, `Product_Year__c = '2026'`, `Product_Category__c = 'Event'`, `Product_Type__c = 'Association'`, `Event_Name__c = 'BizBash MEGA'`
- PricebookEntry query must use `Pricebook2Id = :Test.getStandardPricebookId()` (not `Pricebook2.IsStandard = true`)

### Phase 2: Flow A — "Appointment Taker - Send Registration Emails" ✅ DEPLOYED & ACTIVE
**File:** `force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`
**API Name:** `Appointment_Taker_Send_Registration_Emails`
**Status in org:** Active (V1, last saved 2026-02-10 01:53 AM)

**Trigger:** Record-Triggered on Opportunity (After Update)
**Entry conditions (AND):**
- `StageName = 'Closed Won'`
- `Signer_Contact__c Is Null = false`
- Only when record is updated to meet criteria (won't re-fire on subsequent edits)

**Logic:**
1. Get Records: OLIs where `Product2Id = '01t4X000004U13iQAC'` (Appointment Taker)
2. Loop: Count `varTotalCount` and `varMissingCount` (where Attendee_Name__c or Attendee_Email__c is null)
3. Decision:
   - **All Registered** (missing=0, total>0) → Send confirmation email
   - **Missing Attendees** (missing>0, total>0) → Send follow-up email
   - **No AT Products** (total=0) → Exit silently

**Email configuration (modified in UI after deployment):**
- Sender Type: OrgWideEmailAddress
- Sender Address: `production@connectmeetings.com`
- Follow-up subject: `Action Required: Attendee Details for your Event Registrations`
- Related Record ID: `$Record.Id` (Opportunity)

**Note:** The local XML file may not match the org exactly — the user made UI edits (sender type, sender address, rich text body formatting). Retrieve from org to sync: `sf project retrieve start --metadata "Flow:Appointment_Taker_Send_Registration_Emails" --target-org mac.kitchin@informa.com`

### Phase 3: Prompt Template ✅ EXISTS IN ORG
**File:** `force-app/main/default/genAiPromptTemplates/Extract_Attendee_Information.genAiPromptTemplate-meta.xml`
**API Name:** `Extract_Attendee_Information`
**Type:** `einstein_gpt__flex` (Flex template)
**Model:** `sfdc_ai__DefaultOpenAIGPT4OmniMini`
**Status:** Published

**Input:** `EmailMessage` (SObject, apiName: `EmailMessage`, referenceName: `Input:EmailMessage`)
**Output:** `promptResponse` (String) — raw JSON array of attendees

**Invocable action details (for flow metadata):**
- `actionType: generatePromptResponse`
- `actionName: Extract_Attendee_Information`
- Input parameter name: `Input:EmailMessage`
- Output variable: `promptResponse`

### Phase 4: Flow B — "Event Registration - Process Attendee Reply" ✅ DEPLOYED (Draft)
**File:** `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml`
**API Name:** `Event_Registration_Process_Attendee_Reply`
**Status in org:** Draft (NOT yet activated)

**Trigger:** Record-Triggered on EmailMessage (After Create)
**Entry conditions (AND):**
- `IsIncoming = true`
- `Subject Contains 'Action Required: Attendee Details for your Event Registrations'`

**Logic:**
1. Extract Attendee Information (Prompt Template) → outputs `promptResponse` (JSON)
2. Pass to Apex (ProcessAppointmentTakerAttendees) → `jsonString` = prompt response, `opportunityId` = `$Record.RelatedToId`
3. Decision on `isSuccess` (both paths currently end — no logging/notification yet)

---

## 4. Blocking Issue: Email Routing (UNRESOLVED)

### The Problem
When Flow A sends the follow-up email from `production@connectmeetings.com`, the signer replies to that address. But **no mechanism exists** to route that reply INTO Salesforce as an EmailMessage record. Without an EmailMessage, Flow B never triggers.

### Current Email Infrastructure
- **Org-Wide Addresses:** `production@bizbash.com`, `production@connectmeetings.com`, `wei.zheng@informa.com`
- **Email-to-Case:** Enabled with On-Demand Service, but **no Routing Addresses defined**
- **Email Services:** None configured

### Options Evaluated
1. **Email-to-Case** — Would create unwanted Cases; EmailMessage `RelatedToId` would point to Case (not Opportunity), requiring Flow B modifications
2. **Apex InboundEmailHandler + Email Service** (RECOMMENDED) — Full control, creates EmailMessage linked directly to Opportunity, no unwanted Cases. Requires:
   - Apex class (~60 lines) implementing `Messaging.InboundEmailHandler`
   - Email Service configuration in Setup UI
   - Email forwarding from `production@connectmeetings.com` to SF-generated service address
3. **Dedicated Gmail address** (`attendeeinfo@connectmeetings.com`) — Created but could not receive emails; abandoned

### Next Step
Build the **Apex InboundEmailHandler** class. The handler should:
1. Receive incoming email at the Email Service address
2. Check subject matches the registration pattern
3. Query the original outgoing EmailMessage to find the related Opportunity
4. Insert an incoming EmailMessage linked to that Opportunity
5. This triggers Flow B automatically

---

## 5. What Remains (Ordered)

### Immediate: Inbound Email Handler
- [ ] Create `AttendeeReplyEmailHandler.cls` implementing `Messaging.InboundEmailHandler`
- [ ] Create test class `AttendeeReplyEmailHandlerTest.cls`
- [ ] Deploy both classes
- [ ] Configure Email Service in Setup UI (point to handler, generate address)
- [ ] Set up email forwarding from `production@connectmeetings.com` to the SF service address

### Then: Activate & Test
- [ ] Activate Flow B (currently Draft)
- [ ] E2E test: Create Opportunity → Close Won → Verify follow-up email sent → Reply with attendee list → Verify OLIs updated
- [ ] Verify FLS permissions for all profiles that will run the flow

### Optional Enhancements
- [ ] Add fault handling / error notifications to Flow B
- [ ] Add "send confirmation email after successful processing" step to Flow B
- [ ] Consider what happens if signer sends multiple replies
- [ ] Prompt template tuning (test with various email reply formats)

---

## 6. Key Learnings / Gotchas for This Org

### Flow Metadata XML
- **processType must be `AutoLaunchedFlow`** for record-triggered flows (not `Flow` or `RecordTriggered`)
- Trigger config goes in `<start>` element (not `<recordTriggers>` — that doesn't exist)
- Element types use dedicated tags: `<recordLookups>`, `<loops>`, `<assignments>`, `<decisions>`, `<actionCalls>` (not generic `<elements>` with `<elementSubtype>`)
- **Cross-object field filters don't work** in `<recordLookups>` `<filters>` (e.g., `Product2.Name` fails with `null__NotFound`). Use the ID instead.
- **Prompt template actionType:** `generatePromptResponse` (not `apex`, `generateText`, or `promptTemplate`)
- **Prompt template input param name:** `Input:EmailMessage` (with the `Input:` prefix)
- All elements need explicit `<connector>` tags to the next element
- Each `<value>` needs a typed wrapper: `<stringValue>`, `<numberValue>`, `<booleanValue>`, `<elementReference>`

### Apex Test Class
- Standard Pricebook: use `Test.getStandardPricebookId()`, never query by `IsStandard = true`
- DLRS trigger on OLI fires AfterInsert/AfterUpdate and updates parent Opportunity — parent must have `Sales_Territory__c` set
- Product_Category validation rule cross-checks OLI `Product_Category__c` against `Product2.Opportunity_Product_Category__c`
- Restricted picklist values are record-type-specific — `Sales_Territory__c = 'BizBash'` only valid for certain record types
- USER_MODE DML fails if queried relationship fields are populated on the SObject — create clean instances with only Id + target fields

### Org-Specific IDs (Hardcoded)
- Product2 "Appointment Taker": `01t4X000004U13iQAC`
- Product2 RecordType: `01230000000beHkAAI`
- Opportunity RecordType "Consumer/Meetings": `01230000000bVYmAAM`

---

## 7. File Inventory

```
force-app/main/default/
├── classes/
│   ├── ProcessAppointmentTakerAttendees.cls          ← Invocable Apex (DEPLOYED)
│   ├── ProcessAppointmentTakerAttendees.cls-meta.xml
│   ├── ProcessAppointmentTakerAttendeesTest.cls      ← Test class (7/7 PASSING)
│   └── ProcessAppointmentTakerAttendeesTest.cls-meta.xml
├── flows/
│   ├── Appointment_Taker_Send_Registration_Emails.flow-meta.xml  ← Flow A (ACTIVE in org)
│   └── Event_Registration_Process_Attendee_Reply.flow-meta.xml   ← Flow B (DRAFT in org)
└── genAiPromptTemplates/
    └── Extract_Attendee_Information.genAiPromptTemplate-meta.xml  ← Prompt (PUBLISHED)
```

---

## 8. Useful Commands

```bash
# Deploy Apex classes with tests
sf project deploy start --source-dir force-app/main/default/classes \
  --target-org mac.kitchin@informa.com \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest

# Deploy a specific flow
sf project deploy start --source-dir force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml \
  --target-org mac.kitchin@informa.com

# Retrieve flow from org (to sync UI changes)
sf project retrieve start --metadata "Flow:Appointment_Taker_Send_Registration_Emails" \
  --target-org mac.kitchin@informa.com

# Retrieve prompt templates
sf project retrieve start --metadata "GenAiPromptTemplate" \
  --target-org mac.kitchin@informa.com

# Query Appointment Taker Opportunities
sf data query --query "SELECT Id, Name, StageName, Sales_Territory__c, Signer_Contact__c FROM Opportunity WHERE Id IN (SELECT OpportunityId FROM OpportunityLineItem WHERE Product2.Name = 'Appointment Taker') LIMIT 5" \
  --target-org mac.kitchin@informa.com

# Check available prompt template actions via REST API
# (use curl with access token from sf org display)
```

---

## 9. MCP Server Reference
- **Salesforce MCP server ID:** `2cb05261-a470-48a3-a27b-2a1a01707c95`
- Useful tools: `salesforce_query_records`, `salesforce_describe_object`, `salesforce_aggregate_query`
- `GenAiPromptTemplate` is NOT queryable via SOQL — use `sf project retrieve start --metadata` instead
