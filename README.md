# Attendee Info Agent

An **Agentforce-driven agent** that automates Appointment Taker attendee registration for Connect Meetings event opportunities. When an Opportunity closes won with "Appointment Taker" products, the system sends follow-up emails to collect attendee details. AI extracts attendee data from incoming email replies and writes it to Opportunity Line Items.

## Overview

1. **Opportunity closes won** with Appointment Taker products
2. **Flow A** checks for OLIs with missing attendee info and sends a follow-up email to the Signer Contact
3. **Signer replies** with attendee names and emails
4. **Flow B** (triggered by incoming EmailMessage) uses a GenAI prompt to extract attendee data and invokes Apex to assign it to open OLI slots

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
- **JSON format:** `[{"first_name":"Jane","last_name":"Doe","email":"jane@example.com"}, ...]`
- Assigns attendees to open Appointment Taker OLIs (ordered by CreatedDate)
- Returns `isSuccess` and `statusMessage` with status codes: `SUCCESS_ASSIGNED`, `PARTIAL_ASSIGNED`, `NO_MATCHING_LINE_ITEMS`, `INVALID_JSON`, etc.

### Flows

- **Appointment Taker Send Registration Emails:** Record-triggered on Opportunity (After Update). Fires when `StageName = 'Closed Won'` and sends either confirmation or follow-up email based on OLI attendee status.
- **Event Registration Process Attendee Reply:** Record-triggered on EmailMessage (After Create). Fires on incoming replies matching the registration subject, extracts attendee info via GenAI, and calls the invocable Apex.

### Extract Attendee Information (Prompt Template)

Flex template that parses email subject and body to produce a raw JSON array of `{first_name, last_name, email}` objects.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm) (`sf`)
- Node.js (for LWC Jest tests if applicable)
- A Salesforce org with the required custom fields on Opportunity and OpportunityLineItem (e.g. `Signer_Contact__c`, `Attendee_Name__c`, `Attendee_Email__c`, `Attendee_First_Name__c`)

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
