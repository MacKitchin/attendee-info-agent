/**
 * AttendeeProcessingLogUpdater
 *
 * Invocable Apex class to UPDATE an existing Attendee_Processing_Log__c record.
 * Shows up in Flow Builder as: "Update Attendee Processing Log"
 *
 * WHY THIS EXISTS:
 * ────────────────
 * Flow B (Event_Registration_Process_Attendee_Reply) has a multi-step lifecycle:
 *   1. Receive reply → Create log with status "In Progress" (use AttendeeProcessingLogger)
 *   2. AI extracts attendees → Update log with AI fields + attendee counts (use THIS class)
 *   3. Assign to OLIs → Update log with final counts + status (use THIS class again)
 *   4. If error at any step → Update log with error details + "Failed" status
 *
 * This lets you capture the FULL timeline: when processing started, what the AI
 * returned, how many assignments succeeded, and what went wrong if it failed.
 *
 * USAGE IN FLOW BUILDER:
 * 1. Add an "Action" element AFTER the AI response is received
 * 2. Search for "Update Attendee Processing Log"
 * 3. Pass the processingLogId from step 1 and the new field values
 */
public with sharing class AttendeeProcessingLogUpdater {
  public class UpdateLogInput {
    @InvocableVariable(label='Processing Log ID' required=true)
    public Id processingLogId;

    @InvocableVariable(
      label='Status'
      description='In Progress, Success, Partial Success, Failed'
    )
    public String status;

    @InvocableVariable(label='Attendees Provided')
    public Decimal attendeesProvided;

    @InvocableVariable(label='Attendees Assigned')
    public Decimal attendeesAssigned;

    @InvocableVariable(label='Attendees Not Assigned')
    public Decimal attendeesNotAssigned;

    @InvocableVariable(label='Open Slots Remaining')
    public Decimal openSlotsRemaining;

    @InvocableVariable(label='AI Prompt Input')
    public String aiPromptInput;

    @InvocableVariable(label='AI Raw Response')
    public String aiRawResponse;

    @InvocableVariable(label='AI Model Used')
    public String aiModelUsed;

    @InvocableVariable(label='Error Message')
    public String errorMessage;

    @InvocableVariable(label='Error Category')
    public String errorCategory;
  }

  public class UpdateLogOutput {
    @InvocableVariable(label='Success')
    public Boolean success;

    @InvocableVariable(label='Error Message')
    public String errorMessage;
  }

  @InvocableMethod(
    label='Update Attendee Processing Log'
    description='Updates an existing processing log with AI results, attendee counts, and final status. Call after AI extraction and after OLI assignments.'
    category='Attendee Processing'
  )
  public static List<UpdateLogOutput> updateProcessingLog(
    List<UpdateLogInput> inputs
  ) {
    List<UpdateLogOutput> outputs = new List<UpdateLogOutput>();

    for (UpdateLogInput input : inputs) {
      UpdateLogOutput output = new UpdateLogOutput();
      try {
        Attendee_Processing_Log__c log = new Attendee_Processing_Log__c(
          Id = input.processingLogId
        );

        // Only update fields that were provided (non-null)
        if (input.status != null)
          log.Status__c = input.status;
        if (input.attendeesProvided != null)
          log.Attendees_Provided__c = input.attendeesProvided;
        if (input.attendeesAssigned != null)
          log.Attendees_Assigned__c = input.attendeesAssigned;
        if (input.attendeesNotAssigned != null)
          log.Attendees_Not_Assigned__c = input.attendeesNotAssigned;
        if (input.openSlotsRemaining != null)
          log.Open_Slots_Remaining__c = input.openSlotsRemaining;
        if (input.aiPromptInput != null)
          log.AI_Prompt_Input__c = input.aiPromptInput;
        if (input.aiRawResponse != null)
          log.AI_Raw_Response__c = input.aiRawResponse;
        if (input.aiModelUsed != null)
          log.AI_Model_Used__c = input.aiModelUsed;
        if (input.errorMessage != null)
          log.Error_Message__c = input.errorMessage;
        if (input.errorCategory != null)
          log.Error_Category__c = input.errorCategory;

        update log;

        output.success = true;
      } catch (Exception e) {
        output.success = false;
        output.errorMessage = e.getMessage();
      }
      outputs.add(output);
    }
    return outputs;
  }
}
