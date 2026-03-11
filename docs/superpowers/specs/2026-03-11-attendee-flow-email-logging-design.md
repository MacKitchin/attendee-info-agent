# Attendee Flow Email Logging Design

## Context

The attendee registration automation has two related gaps:

- Flow A (`Appointment_Taker_Send_Registration_Emails`) sends emails without creating an `Attendee_Processing_Log__c` audit trail and without fault handling.
- Flow B (`Event_Registration_Process_Attendee_Reply`) creates and updates logs, but does not populate `Email_Subject__c` or `Recipients__c`.
- `AttendeeProcessingLogUpdater` cannot clear stale string fields because `null` currently means "leave unchanged" for every input.

## Goals

- Create a durable audit trail for outbound registration emails.
- Capture recipient and subject metadata on processing logs.
- Handle Flow A email failures explicitly instead of allowing uncaught flow errors.
- Avoid misleading completion emails from Flow A when registrations were already pre-filled before the flow ran.
- Preserve existing inbound reply processing behavior while making log updates more accurate.

## Non-Goals

- Global normalization of all flow API versions in the repository.
- Reworking the `ProcessAppointmentTakerAttendees` assignment algorithm.
- Replacing Salesforce email actions with Apex email sending.

## Approved Approach

### 1. Extend Processing Log Apex interfaces

Update `AttendeeProcessingLogger` and `AttendeeProcessingLogUpdater` so both invocable wrappers can accept:

- `emailSubject`
- `recipients`

Map those inputs to:

- `Attendee_Processing_Log__c.Email_Subject__c`
- `Attendee_Processing_Log__c.Recipients__c`

### 2. Support explicit clearing in the updater

Preserve `null` as "do not update" for backwards compatibility, but treat blank strings as an intentional clear for string fields that may need cleanup:

- `AI_Prompt_Input__c`
- `AI_Raw_Response__c`
- `AI_Model_Used__c`
- `Error_Message__c`
- `Error_Category__c`
- `Email_Subject__c`
- `Recipients__c`

This allows success paths to clear stale error text without forcing every caller to supply replacement values.

### 3. Change Flow A behavior

For `Appointment_Taker_Send_Registration_Emails`:

- Remove the "all registered" outbound email branch.
- Keep the follow-up email branch for missing attendee data.
- Create an outbound `Attendee_Processing_Log__c` record before the follow-up email send.
- Populate the outbound log with:
  - Opportunity ID
  - Processing Type = `Outbound Email`
  - Status = `In Progress`
  - Total Registration Products
  - Recipients = signer email
  - Email Subject = follow-up subject
  - Flow API name
  - Flow interview GUID
- On successful send, update the log to `Success`.
- On send fault, capture `$Flow.FaultMessage`, update the log to `Failed`, and store the error category/message.

### 4. Change Flow B logging

For `Event_Registration_Process_Attendee_Reply`:

- Populate `Email_Subject__c` from `$Record.Subject` when creating the processing log.
- Populate `Recipients__c` from the inbound message address fields, using `$Record.ToAddress`.

## Tradeoffs

- Treating blank string as clear is slightly broader than the immediate bug, but it is the smallest Apex surface that makes the log updater reusable and fixes the persistence issue without adding per-field boolean flags.
- Removing the Flow A "completed" email is simpler and less misleading than inventing a third outbound message for pre-filled registrations.
- Keeping email send in Flow rather than Apex limits implementation risk and preserves current admin editability.

## Verification Strategy

- Add Apex tests covering:
  - logger creation with subject/recipients
  - updater clearing stale error fields
- Run targeted Apex tests after code changes.
- Validate flow metadata diffs for:
  - new log action wiring
  - fault connectors
  - removal of the completed email path
  - new Flow B field mappings
