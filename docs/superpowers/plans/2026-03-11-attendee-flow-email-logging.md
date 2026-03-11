# Implementation Plan: Attendee Flow Email Logging

I’m using the writing-plans skill to create the implementation plan.

## File Map

- Modify: `force-app/main/default/classes/AttendeeProcessingLogger.cls`
- Modify: `force-app/main/default/classes/AttendeeProcessingLogUpdater.cls`
- Modify: `force-app/main/default/classes/AttendeeProcessingLoggerTest.cls`
- Modify: `force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`
- Modify: `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml`

## Chunk 1: Apex Log Inputs And Clearing Semantics

### Task 1: Add failing tests for logger subject/recipient support

**Files:**
- Modify: `force-app/main/default/classes/AttendeeProcessingLoggerTest.cls`
- Modify: `force-app/main/default/classes/AttendeeProcessingLogger.cls`

- [ ] Step 1: Extend the existing create-log success test to assert `emailSubject` and `recipients` are stored.
- [ ] Step 2: Run `sf project deploy start --dry-run --ignore-conflicts --source-dir force-app/main/default/classes/AttendeeProcessingLogger.cls --source-dir force-app/main/default/classes/AttendeeProcessingLogUpdater.cls --source-dir force-app/main/default/classes/AttendeeProcessingLoggerTest.cls --target-org mac.kitchin@informa.com --test-level RunSpecifiedTests --tests AttendeeProcessingLoggerTest` and confirm the local validation fails before the Apex changes are made.
- [ ] Step 3: Add `emailSubject` and `recipients` invocable inputs to `AttendeeProcessingLogger.ProcessingLogInput`.
- [ ] Step 4: Map those inputs to `Email_Subject__c` and `Recipients__c`.
- [ ] Step 5: Re-run the same dry-run deploy validation and confirm the local Apex changes compile cleanly.

### Task 2: Add failing tests for clearing stale string fields

**Files:**
- Modify: `force-app/main/default/classes/AttendeeProcessingLoggerTest.cls`
- Modify: `force-app/main/default/classes/AttendeeProcessingLogUpdater.cls`

- [ ] Step 1: Extend the existing updater coverage with a test that creates a failed log, then updates it with blank `errorMessage`, blank `errorCategory`, blank `emailSubject`, and blank `recipients`, and asserts those fields are cleared.
- [ ] Step 2: Run the same dry-run deploy validation and confirm the local validation fails before the updater changes are made.
- [ ] Step 3: Update `AttendeeProcessingLogUpdater` so `null` means “leave unchanged” and blank string means “clear” for supported string fields.
- [ ] Step 4: Add updater inputs for `emailSubject` and `recipients`, using the same clear semantics.
- [ ] Step 5: Re-run the same dry-run deploy validation and confirm the full test class compiles cleanly.

## Chunk 2: Flow B Logging Completion

### Task 3: Populate subject and recipients on inbound log creation

**Files:**
- Modify: `force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml`

- [ ] Step 1: Add `emailSubject = $Record.Subject` to `Create_Attendee_Processing_Log`.
- [ ] Step 2: Add `recipients = $Record.ToAddress` to `Create_Attendee_Processing_Log`.
- [ ] Step 3: Inspect the metadata diff to confirm only the intended Flow B action inputs changed.

## Chunk 3: Flow A Outbound Logging And Fault Handling

### Task 4: Remove misleading completed-email path

**Files:**
- Modify: `force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`

- [ ] Step 1: Remove the `Action_Send_Completed_Email` action block.
- [ ] Step 2: Rewire the `Outcome_All_Registered` branch to exit without sending email.
- [ ] Step 3: Inspect the metadata diff to confirm no remaining references to the completed-email action.

### Task 5: Add outbound processing log and follow-up success/failure updates

**Files:**
- Modify: `force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml`

- [ ] Step 1: Add a variable to store the outbound processing log ID.
- [ ] Step 2: Add a `Create Attendee Processing Log` action before the follow-up email send.
- [ ] Step 3: Map processing type, status, totals, subject, recipients, flow metadata, and opportunity ID into that action.
- [ ] Step 4: Add an `Update Attendee Processing Log` action after successful send to mark the log `Success`.
- [ ] Step 5: Add a fault path from the follow-up email action that stores `$Flow.FaultMessage` and updates the log to `Failed`.
- [ ] Step 6: Inspect the metadata diff to confirm the follow-up path now has success and failure logging.

## Chunk 4: Verification

### Task 6: Run targeted verification

**Files:**
- Modify: none

- [ ] Step 1: Run `sf project deploy start --dry-run --ignore-conflicts --source-dir force-app/main/default/classes/AttendeeProcessingLogger.cls --source-dir force-app/main/default/classes/AttendeeProcessingLogUpdater.cls --source-dir force-app/main/default/classes/AttendeeProcessingLoggerTest.cls --source-dir force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml --source-dir force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml --target-org mac.kitchin@informa.com --test-level RunSpecifiedTests --tests AttendeeProcessingLoggerTest`.
- [ ] Step 2: Run `git diff -- force-app/main/default/classes/AttendeeProcessingLogger.cls force-app/main/default/classes/AttendeeProcessingLogUpdater.cls force-app/main/default/classes/AttendeeProcessingLoggerTest.cls force-app/main/default/flows/Appointment_Taker_Send_Registration_Emails.flow-meta.xml force-app/main/default/flows/Event_Registration_Process_Attendee_Reply.flow-meta.xml docs/superpowers/specs/2026-03-11-attendee-flow-email-logging-design.md docs/superpowers/plans/2026-03-11-attendee-flow-email-logging.md`.
- [ ] Step 3: Review the diff for unintended changes and report exact verification results plus deployment caveats.
