# Attendee Info Agent

An **Agentforce-driven agent** that automates attendee registration for Connect Meetings event opportunities. When an Opportunity closes won with supported attendee-registration products, the system sends follow-up emails to collect attendee details. AI extracts attendee data from incoming email replies and writes it to Opportunity Line Items.

## Overview

1. **Opportunity closes won** with supported attendee-registration products:
   - Appointment Taker (`01t4X000004U13iQAC`)
   - Non-Appointment Taker (`01t4X000004U14AQAS`)
   - Marketer (`01t4X000004U148QAC`)
2. **Flow A** checks for OLIs with missing attendee info and sends a follow-up email to the Signer Contact
3. **Signer replies** with attendee names and emails
4. **Flow B** (triggered by incoming EmailMessage) uses a GenAI prompt to extract attendee data and invokes Apex to assign it to open OLI slots
5. **Apex** populates `Event_Attendee_Contact__c` lookup by matching attendee email to existing Contacts on the Opportunity's Account
6. **Notification emails** sent to `mac.kitchin@informa.com` on success or failure with Account, Opportunity, and Contact details

## Project Structure

```
force-app/main/default/
├── classes/
│   ├── ProcessAppointmentTakerAttendees.cls     # Invocable Apex - maps attendees to OLIs
│   └── ProcessAppointmentTakerAttendeesTest.cls  # Unit tests
├── flows/
│   ├── Appointment_Taker_Send_Registration_Emails.flow-meta.xml  # Flow A - sends follow-up emails
│   └── Event_Registration_Process_Attendee_Reply.flow-meta.xml  # Flow B - processes replies
└── genAiPromptTemplates/
    └── Extract_Attendee_Information.genAiPromptTemplate-meta.xml # AI extraction from email
```

## Key Components

### ProcessAppointmentTakerAttendees (Invocable Apex)

- **Inputs:** `jsonString` (JSON array of attendees), `opportunityId`
- **JSON format:** `[{"first_name":"Jane","last_name":"Doe","email":"jane@example.com","event_name":"BizBash MEGA","product_type":"Association"}, ...]` (`event_name` and `product_type` are optional)
- Assigns attendees to open supported registration OLIs (Appointment Taker, Non-Appointment Taker, and Marketer)
- Matching behavior:
  - First tries event-aware matching by `event_name + product_type`
  - Falls back to next available slot by `CreatedDate` order
- Populates `Event_Attendee_Contact__c` lookup field by matching attendee email to Contacts on the Opportunity's Account
- Returns `isSuccess` and `statusMessage` with status codes: `SUCCESS_ASSIGNED`, `PARTIAL_ASSIGNED`, `NO_MATCHING_LINE_ITEMS`, `INVALID_JSON`, etc.

### Flows

- **Appointment Taker Send Registration Emails:** Record-triggered on Opportunity (After Update). Fires when `StageName = 'Closed Won'`, checks supported Product2 IDs (Appointment Taker, Non-Appointment Taker, Marketer), and sends either confirmation or follow-up email based on OLI attendee status. Each requested line in the follow-up email includes Event, Registration Type, and Type.
- **Event Registration Process Attendee Reply:** Record-triggered on EmailMessage (After Create). Fires on incoming replies matching the registration subject, queries Opportunity details, extracts attendee info via GenAI, calls the invocable Apex to update supported registration OLIs, and sends success/failure notification emails to `mac.kitchin@informa.com` with Account, Opportunity, and Contact details. Includes fault handling for GenAI prompt and Apex errors.

### Extract Attendee Information (Prompt Template)

Flex template that parses email subject and body to produce a raw JSON array of attendee objects. Core fields are `{first_name, last_name, email}` and it may also include event context fields such as `{event_name, product_type}`.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm) (`sf`)
- Node.js (for LWC Jest tests if applicable)
- A Salesforce org with the required custom fields on Opportunity and OpportunityLineItem (e.g. `Signer_Contact__c`, `Attendee_Name__c`, `Attendee_Email__c`, `Attendee_First_Name__c`, `Event_Attendee_Contact__c`, `Event_Name__c`, `Product_Type__c`)

## Setup & Deployment

### Deploy to target org

```bash
# Deploy all metadata
sf project deploy start --target-org <alias>

# Deploy Apex with tests
sf project deploy start --source-dir force-app/main/default/classes \
  --target-org <alias> \
  --test-level RunSpecifiedTests \
  --tests ProcessAppointmentTakerAttendeesTest

# Deploy a specific flow
sf project deploy start --source-dir force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml \
  --target-org <alias>
```

### Retrieve from org (sync UI changes)

```bash
sf project retrieve start --metadata "Flow:Appointment_Taker_Send_Registration_Emails" --target-org <alias>
sf project retrieve start --metadata "GenAiPromptTemplate" --target-org <alias>
```

## Development

```bash
npm install
npm run lint              # ESLint (LWC/Aura)
npm run prettier:verify   # Check formatting
npm run prettier          # Format code
```

## Documentation

- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [Salesforce CLI Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)

For implementation details, org-specific configuration, and known issues (e.g. email routing), see `salesforce-visit-sync_session-2026-02-11.md` in this repository.
