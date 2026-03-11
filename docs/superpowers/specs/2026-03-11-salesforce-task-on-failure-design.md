# Design: Salesforce Task Creation on Attendee Assignment Failure

**Date:** 2026-03-11
**Status:** Approved
**Author:** Mac Kitchin / Claude Code

---

## Overview

When attendee assignment results in `Partial Success` or `Failed`, the existing flow sends a failure email to `mac.kitchin@informa.com`. This feature adds a Salesforce Task (standard `Task` object) assigned to Mac Kitchin, linked to the Opportunity, containing an AI-generated narrative explaining what failed, why it failed, who (if anyone) was successfully assigned, and any known reasons for the failures.

This is additive — existing email notifications are unchanged.

---

## Trigger Conditions

A Task is created when `ProcessAppointmentTakerAttendees` returns `finalStatus` of either:
- `Partial Success` — some attendees assigned, some skipped or failed
- `Failed` — no attendees could be assigned, or a processing error occurred

A Task is **not** created on `Success`.

### Important: `isSuccess` vs `finalStatus`

`ProcessAppointmentTakerAttendees` sets `isSuccess = true` in more cases than just `Success` and `Partial Success`. Reviewing the actual class code, the following `finalStatus = 'Failed'` paths **also** return `isSuccess = true`:

- Empty `jsonString` → `isSuccess = true`, `finalStatus = 'Failed'`
- No attendees found in JSON (AI extracted nothing) → `isSuccess = true`, `finalStatus = 'Failed'`
- No matching OLI slots found → `isSuccess = true`, `finalStatus = 'Failed'`
- `toUpdate` is empty after processing → `isSuccess = true`, `finalStatus = 'Failed'`

Only the path where `successCount == 0` *and* there are DML errors sets `isSuccess = false`. The existing Flow decision branches on `varIsSuccess`, meaning **all of the above Failed paths** exit through the success branch, not the failure branch.

This means a `Decision_Needs_Task` node on **only** the non-success branch would miss most failure cases. The second decision node must be placed on **both** branches.

To correctly cover all `Partial Success` and `Failed` outcomes, a **second decision node** is added after the existing `Decision_Is_Success`:

```
Decision_Is_Success?
  → isSuccess = false → [existing failure path] Update Log → Send Failure Email
                             → [NEW] Decision_Needs_Task: finalStatus != 'Success' → task steps
  → isSuccess = true  → [existing success path] Update Log → Send Success Email
                             → [NEW] Decision_Needs_Task: finalStatus != 'Success' → task steps
```

Concretely: both the success and non-success paths get a `Decision_Needs_Task` node (checking `varFinalStatus != 'Success'`) inserted **after** their respective log update and email send steps. Both nodes point to the same new task-creation steps.

---

## New Components

### 1. `BuildFailureContext` — Invocable Apex Class

**Purpose:** Queries `Attendee_Assignment_Detail__c` records for the current processing run and returns a structured plain-text summary for use as AI prompt input.

**Input fields:**
| Field | Type | Required | Description |
|---|---|---|---|
| `processingLogId` | Id | No | The `Attendee_Processing_Log__c` record for this run |
| `statusMessage` | String | Yes | Aggregate status message from `ProcessAppointmentTakerAttendees` |
| `opportunityName` | String | Yes | Opportunity name (for context) |

**Null `processingLogId` handling:** If `processingLogId` is null (e.g. because `Create_Attendee_Processing_Log` faulted), the class skips the SOQL queries and returns a minimal context block using only `opportunityName` and `statusMessage`:
```
Opportunity: <name>
Overall Status: <statusMessage>

No detailed assignment records are available for this run.
```

**What it does (when processingLogId is present):**
1. Queries `Attendee_Assignment_Detail__c` WHERE `Processing_Log__c = processingLogId` AND `Assignment_Status__c = 'Assigned'` WITH USER_MODE — for the success context
2. Queries `Attendee_Assignment_Detail__c` WHERE `Processing_Log__c = processingLogId` AND `Assignment_Status__c IN ('Failed', 'Skipped')` WITH USER_MODE — for the failure detail
3. Formats all records into a structured text block:

```
Opportunity: <name>
Overall Status: <statusMessage>

ASSIGNED ATTENDEES:
1. Jane Doe (jane@company.com) — Event: BizBash MEGA | Product: Appointment Taker

FAILED / SKIPPED ATTENDEES:
1. John Smith (john@company.com) — Event: BizBash MEGA | Product: Non-Appointment Taker
   Reason: No available open registration slot for attendee.
2. ...
```

**Output fields:**
| Field | Type | Description |
|---|---|---|
| `formattedContext` | String | The structured text block, truncated to 10,000 characters from the end (preserving the header, truncating older detail lines from the middle if necessary). A `[truncated]` marker is appended if truncation occurred. |

**Truncation strategy:** Build the full string; if `length() > 10000`, apply truncation in this order:
1. First drop complete attendee lines from the middle of the failed/skipped section until it fits, then append `\n[truncated — some records omitted]`.
2. If the header + full assigned section alone exceeds 10,000 characters (e.g., hundreds of assigned attendees), also trim complete assigned attendee lines from the end of the assigned section, appending `\n[truncated — some assigned records omitted]`.
3. The header block (`Opportunity:` + `Overall Status:`) and at least the first entry in each section are always preserved regardless of length.

**Pattern:** Follows `AttendeeAssignmentDetailLogger` — small, single-purpose invocable.

---

### 2. `Attendee_Assignment_Failure_Summary` — GenAI Prompt Template

**Purpose:** Takes the structured failure context from `BuildFailureContext` and produces a human-readable, plain-English narrative explaining the outcome.

**Template type:** `einstein_gpt__flex` (same type as `Extract_Attendee_Information`)

**Model:** `sfdc_ai__DefaultBedrockAnthropicClaude45Haiku` (same as `Extract_Attendee_Information`)

**Assumption:** This model alias is confirmed available in the target org (already used by `Extract_Attendee_Information`).

**Input variable:**
| API Name | Type | Flow mapping |
|---|---|---|
| `FailureContext` | String (text) | `varFormattedContext` (output of `BuildFailureContext`) |

The Flow invokes this template via `actionType: generatePromptResponse` with input parameter name `Input:FailureContext` mapped to `varFormattedContext`, using `<storeOutputAutomatically>true</storeOutputAutomatically>` — identical to how `Extract_Attendee_Information` is invoked. The prompt response is then referenced in the Flow as `Attendee_Assignment_Failure_Summary.promptResponse` (not via a separate named variable). **`varAiSummary` is therefore not a declared flow variable** — the `CreateFollowUpTask` input mapping uses `Attendee_Assignment_Failure_Summary.promptResponse` directly.

**Prompt behaviour:** The prompt instructs the model to:
- Summarise what happened (how many attendees were provided, how many assigned)
- List who was assigned successfully (if any)
- List who could not be assigned, with plain-English explanation of each failure reason
- If the failure reason is a system error (DML, validation rule), explain what that means in plain English
- If the reason is "no available slot", explain that there were more attendees provided than open registration line items
- Output as clean prose suitable for a Salesforce Task description (no markdown, no code blocks)

**Expected output:** 150–400 words of plain prose.

---

### 3. `CreateFollowUpTask` — Invocable Apex Class

**Purpose:** Creates a Salesforce `Task` linked to the Opportunity and assigned to Mac Kitchin, using the AI-generated summary as the description.

**Input fields:**
| Field | Type | Required | Description |
|---|---|---|---|
| `opportunityId` | Id | Yes | Used as `Task.WhatId` |
| `aiSummary` | String | No | AI-generated narrative from the prompt template |
| `opportunityName` | String | Yes | Used in Task subject (truncated to 200 chars before concatenation) |
| `statusMessage` | String | No | Fallback content if `aiSummary` is blank |

**What it does:**
1. Queries `User` WHERE `Email = 'mac.kitchin@informa.com'` WITH SYSTEM_MODE, LIMIT 1.
   - **Rationale for SYSTEM_MODE:** The flow runs as the Automated Process system user, whose profile may not have visibility into the User object. SYSTEM_MODE ensures the lookup always works, consistent with the write-side approach in `ProcessAppointmentTakerAttendees`.
   - Falls back to `UserInfo.getUserId()` if no match found. Logs a warning via `System.debug(LoggingLevel.WARN, ...)`.
2. Builds Task description:
   - If `aiSummary` is not blank: use `aiSummary`
   - If `aiSummary` is blank: use `'Attendee assignment completed with status: ' + statusMessage + '. AI summary was unavailable.'`
3. Builds Task subject: `'Review Attendee Assignment Failures — ' + opportunityName.left(200)`
4. Inserts a `Task` with `AccessLevel.SYSTEM_MODE`:

| Task Field | Value |
|---|---|
| `Subject` | `'Review Attendee Assignment Failures — ' + opportunityName.left(200)` |
| `WhatId` | `opportunityId` |
| `OwnerId` | Mac Kitchin's User Id (or running user fallback) |
| `ActivityDate` | `Date.today().addDays(30)` |
| `Status` | `Not Started` |
| `Priority` | `Normal` |
| `Description` | `aiSummary` or fallback string |
| `Type` | `Other` |

**Pattern:** Follows `AttendeeAssignmentDetailLogger` — small, single-purpose invocable.

---

## Flow Changes — `Event_Registration_Process_Attendee_Reply`

### New Flow Variables

One new String variable must be added to the flow's `<variables>` block:

| Variable API Name | Type | Description |
|---|---|---|
| `varFormattedContext` | String | Output of `BuildFailureContext`; passed as input to the prompt template |

`varAiSummary` is **not** a declared variable. Because `Attendee_Assignment_Failure_Summary` uses `storeOutputAutomatically = true`, its output is referenced directly as `Attendee_Assignment_Failure_Summary.promptResponse` in the `CreateFollowUpTask` input mapping — the same pattern used by `Extract_Attendee_Information.promptResponse`.

### New Steps (added on both success and non-success paths)

After the existing log update and email send on **both** branches, a `Decision_Needs_Task` node checks `varFinalStatus != 'Success'`. When true, the following three steps execute:

```
[NEW] Decision_Needs_Task (finalStatus != 'Success')
  → YES:
       [NEW] BuildFailureContext (Apex invocable)
            Inputs:  processingLogId = varProcessingLogId
                     statusMessage   = varStatusMessage
                     opportunityName = Get_Opportunity_Details.Name
            Output:  varFormattedContext

       [NEW] Attendee_Assignment_Failure_Summary (generatePromptResponse)
            Input:   Input:FailureContext = varFormattedContext
            Output:  storeOutputAutomatically = true
                     (referenced as Attendee_Assignment_Failure_Summary.promptResponse)

       [NEW] CreateFollowUpTask (Apex invocable)
            Inputs:  opportunityId   = $Record.RelatedToId
                     aiSummary       = Attendee_Assignment_Failure_Summary.promptResponse
                     opportunityName = Get_Opportunity_Details.Name
                     statusMessage   = varStatusMessage
  → NO: (end — no task needed)
```

A fault connector on each new step routes to the existing `Assign_Fault_Message` fault handler, so a failure in task creation does not break the overall flow run.

### Corrected Flow Diagram

```
Decision_Is_Success?
  ├─ isSuccess = false
  │    → Update Log (Failed) → Send Failure Email
  │         → Decision_Needs_Task
  │              → YES → BuildFailureContext → Prompt → CreateFollowUpTask
  │              → NO  → (end)
  └─ isSuccess = true
       → Update Log (Success/Partial) → Send Success Email
            → Decision_Needs_Task
                 → YES → BuildFailureContext → Prompt → CreateFollowUpTask
                 → NO  → (end)
```

---

## Data Flow Diagram

```
ProcessAppointmentTakerAttendees result (Partial Success or Failed)
  │
  ▼
[Existing] Update Processing Log + Send Email (success or failure variant)
  │
  ▼
Decision_Needs_Task: varFinalStatus != 'Success'?
  │ YES
  ▼
BuildFailureContext
  Queries: Attendee_Assignment_Detail__c (Assigned + Failed + Skipped for this log)
  Returns: varFormattedContext (structured plain text, ≤ 10,000 chars)
  │
  ▼
Attendee_Assignment_Failure_Summary prompt template
  Input:   varFormattedContext
  Returns: Attendee_Assignment_Failure_Summary.promptResponse (plain prose narrative)
  │
  ▼
CreateFollowUpTask
  Queries: User by email mac.kitchin@informa.com (SYSTEM_MODE)
  Inserts: Task linked to Opportunity, assigned to Mac Kitchin, due in 30 days
```

---

## Task Record Example

```
Subject:      Review Attendee Assignment Failures — BizBash MEGA 2026 (Acme Corp)
What:         [linked Opportunity]
Assigned To:  Mac Kitchin
Due Date:     2026-04-10
Status:       Not Started
Priority:     Normal
Description:
  The system processed 3 attendees from the registration reply email but was only
  able to assign 1 successfully.

  Successfully assigned:
  - Jane Doe (jane@company.com) to BizBash MEGA / Appointment Taker

  Could not be assigned:
  - John Smith (john@company.com) — There were no open registration slots for the
    Non-Appointment Taker product on this opportunity. All available slots were
    already filled or taken by other attendees in this batch.
  - Alice Jones (alice@company.com) — No matching registration line item was found
    for this event and product type combination. The attendee may have been listed
    for a product not included on this opportunity.
```

---

## Files to Create / Modify

| File | Action |
|---|---|
| `force-app/main/default/classes/BuildFailureContext.cls` | Create |
| `force-app/main/default/classes/BuildFailureContext.cls-meta.xml` | Create |
| `force-app/main/default/classes/BuildFailureContextTest.cls` | Create |
| `force-app/main/default/classes/BuildFailureContextTest.cls-meta.xml` | Create |
| `force-app/main/default/classes/CreateFollowUpTask.cls` | Create |
| `force-app/main/default/classes/CreateFollowUpTask.cls-meta.xml` | Create |
| `force-app/main/default/classes/CreateFollowUpTaskTest.cls` | Create |
| `force-app/main/default/classes/CreateFollowUpTaskTest.cls-meta.xml` | Create |
| `force-app/main/default/genAiPromptTemplates/Attendee_Assignment_Failure_Summary.genAiPromptTemplate-meta.xml` | Create |
| `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml` | Modify |

---

## Security Model

| Class | Operation | Mode | Rationale |
|---|---|---|---|
| `BuildFailureContext` | SOQL reads on `Attendee_Assignment_Detail__c` | `WITH USER_MODE` | Standard read enforcement consistent with existing classes |
| `CreateFollowUpTask` | SOQL lookup of `User` by email | `WITH SYSTEM_MODE` | Automated Process user profile may not have User object visibility |
| `CreateFollowUpTask` | `Task` insert | `AccessLevel.SYSTEM_MODE` | Automated process user needs to write Task fields regardless of FLS |

---

## Testing

`BuildFailureContextTest`:
- Returns minimal context block when `processingLogId` is null (no SOQL, uses statusMessage only)
- Returns minimal context block when no detail records exist for the log
- Formats correctly with Assigned records only (no failures)
- Formats correctly with mixed Assigned + Failed + Skipped records
- Correctly truncates output to ≤ 10,000 characters and appends `[truncated]` marker

`CreateFollowUpTaskTest`:
- Creates Task with correct `WhatId`, `OwnerId` (matched by email), `ActivityDate` (today + 30), Subject, Description
- Subject truncates `opportunityName` correctly when > 200 characters
- Falls back to running user's ID when `mac.kitchin@informa.com` is not found; logs a warning
- Uses fallback description string when `aiSummary` is blank (includes `statusMessage` content)
- Uses `aiSummary` as description when present

---

## Deployment

Add to the existing deploy command:
```bash
--metadata ApexClass:BuildFailureContext \
--metadata ApexClass:BuildFailureContextTest \
--metadata ApexClass:CreateFollowUpTask \
--metadata ApexClass:CreateFollowUpTaskTest \
--metadata GenAiPromptTemplate:Attendee_Assignment_Failure_Summary \
--metadata Flow:Event_Registration_Process_Attendee_Reply \
--tests BuildFailureContextTest \
--tests CreateFollowUpTaskTest
```
