# Attendee Processing Logger — Deployment & Flow Integration Guide

## 1. Deploy the Apex Classes

Since this is a production org, use one of these methods:

### Option A: Change Set (Recommended for non-developers)

1. Create the classes in your **Sandbox** first (Setup → Apex Classes → New)
2. Copy-paste each `.cls` file into a new Apex Class
3. Create an **Outbound Change Set** containing all 4 classes
4. Upload to Production and deploy

### Option B: SFDX / Metadata API

```bash
sfdx force:source:deploy -p Attendee_Logging_Deploy/classes -u your-production-alias
```

### Option C: Workbench

1. Zip the `classes/` folder + `package.xml` into a single `.zip`
2. Go to workbench.developerforce.com → Migration → Deploy
3. Upload the zip and deploy

---

## 2. Integrate with Flow A: Appointment_Taker_Send_Registration_Emails

Add **one** Action element at the END of the flow, after the email is sent:

### Action: "Create Attendee Processing Log"

| Flow Variable →                                | Apex Input Parameter            |
| ---------------------------------------------- | ------------------------------- |
| `{!$Record.Id}` (or your Opp variable)         | **Opportunity ID**              |
| `"Outbound Email"`                             | **Processing Type**             |
| `"Success"` (or use a fault path for "Failed") | **Status**                      |
| Count of registration OLIs                     | **Total Registration Products** |
| `"Appointment_Taker_Send_Registration_Emails"` | **Flow API Name**               |

This creates a log entry every time the flow sends registration emails.

---

## 3. Integrate with Flow B: Event_Registration_Process_Attendee_Reply

This flow needs **three** integration points:

### Step 1: Create Log (at the START, after receiving the EmailMessage)

**Action: "Create Attendee Processing Log"**

| Flow Variable →                               | Apex Input Parameter            |
| --------------------------------------------- | ------------------------------- |
| Opportunity ID (from REG token)               | **Opportunity ID**              |
| `"Inbound Reply"`                             | **Processing Type**             |
| `"In Progress"`                               | **Status**                      |
| `{!$Record.Id}` (EmailMessage ID)             | **Inbound Email Message ID**    |
| Original outgoing EmailMessage ID             | **Outgoing Email Message ID**   |
| Sender email from EmailMessage                | **Sender Email**                |
| Sender name from EmailMessage                 | **Sender Name**                 |
| Count of registration OLIs                    | **Total Registration Products** |
| `"Event_Registration_Process_Attendee_Reply"` | **Flow API Name**               |

**Store the output `processingLogId` in a variable** — you'll need it for Steps 2 and 3.

### Step 2: Update Log (AFTER AI extraction, BEFORE OLI assignment loop)

**Action: "Update Attendee Processing Log"**

| Flow Variable →                 | Apex Input Parameter   |
| ------------------------------- | ---------------------- |
| `{!varProcessingLogId}`         | **Processing Log ID**  |
| The prompt you sent to the AI   | **AI Prompt Input**    |
| The raw AI response text        | **AI Raw Response**    |
| `"gpt-4"` or whatever model     | **AI Model Used**      |
| Count of attendees AI extracted | **Attendees Provided** |

### Step 3: Log Each Assignment (INSIDE the OLI assignment loop)

For **each** OLI your flow processes, add this action:

**Action: "Log Attendee Assignment Detail"**

| Flow Variable →                                               | Apex Input Parameter             |
| ------------------------------------------------------------- | -------------------------------- |
| `{!varProcessingLogId}`                                       | **Processing Log ID**            |
| Current OLI ID                                                | **Opportunity Product (OLI) ID** |
| Product name from OLI                                         | **Product Name**                 |
| Product type (AT/NAT/Marketer)                                | **Product Type**                 |
| Event name                                                    | **Event Name**                   |
| AI-extracted attendee name                                    | **Extracted Name**               |
| AI-extracted email                                            | **Extracted Email**              |
| AI-extracted phone                                            | **Extracted Phone**              |
| Matched Contact ID                                            | **Assigned Contact ID**          |
| `"Assigned"` / `"Failed"` / etc.                              | **Assignment Status**            |
| Error message if failed                                       | **Assignment Error**             |
| **OLI's CURRENT Attendee_Name\_\_c** (before update)          | **Previous Attendee Name**       |
| **OLI's CURRENT Attendee_Email\_\_c** (before update)         | **Previous Attendee Email**      |
| **OLI's CURRENT Event_Attendee_Contact\_\_c** (before update) | **Previous Contact ID**          |

> **Important**: Read the OLI's current attendee fields INTO variables BEFORE you
> update the OLI. Then pass those "before" values to the logger. This creates
> your audit trail showing what was overwritten.

### Step 4: Final Status Update (AFTER the loop completes)

**Action: "Update Attendee Processing Log"**

| Flow Variable →                                | Apex Input Parameter       |
| ---------------------------------------------- | -------------------------- |
| `{!varProcessingLogId}`                        | **Processing Log ID**      |
| `"Success"` / `"Partial Success"` / `"Failed"` | **Status**                 |
| Final count of assigned                        | **Attendees Assigned**     |
| Final count of not assigned                    | **Attendees Not Assigned** |
| Remaining open slots                           | **Open Slots Remaining**   |

### Fault Path: If anything fails

On any Fault connector, add:

**Action: "Update Attendee Processing Log"**

| Flow Variable →                       | Apex Input Parameter  |
| ------------------------------------- | --------------------- |
| `{!varProcessingLogId}`               | **Processing Log ID** |
| `"Failed"`                            | **Status**            |
| `{!$Flow.FaultMessage}`               | **Error Message**     |
| `"DML Error"` / `"JSON Parse"` / etc. | **Error Category**    |

---

## 4. Viewing Your Logs

Once deployed and integrated, you can view logs via:

- **Attendee Processing Logs tab** → List Views (pre-configured)
- **Opportunity page** → Related List "Attendee Processing Logs"
- **Reports** → Custom Report Type "Attendee Processing with Assignment Details"
- **Interactive Dashboard** → HTML file provided separately
