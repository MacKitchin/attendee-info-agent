/**
 * AttendeeProcessingLogger
 *
 * Invocable Apex class that Flows call to create Attendee_Processing_Log__c records.
 * Shows up in Flow Builder as an "Action" element: "Create Attendee Processing Log"
 *
 * USAGE IN FLOW BUILDER:
 * ─────────────────────
 * 1. Open your Flow (e.g., Event_Registration_Process_Attendee_Reply)
 * 2. Add an "Action" element at the START of processing
 * 3. Search for "Create Attendee Processing Log"
 * 4. Map your Flow variables to the labeled input parameters
 * 5. Store the output "processingLogId" in a Flow variable — you'll pass it
 *    to AttendeeAssignmentDetailLogger for each OLI assignment
 *
 * FLOW A (Appointment_Taker_Send_Registration_Emails):
 *   - Call with processingType = "Outbound Email"
 *   - Set totalRegistrationProducts to the count of registration OLIs
 *   - Set status to "Success" or "Failed" after email send
 *
 * FLOW B (Event_Registration_Process_Attendee_Reply):
 *   - Call EARLY with processingType = "Inbound Reply", status = "In Progress"
 *   - After AI extraction, UPDATE the log with attendee counts + AI fields
 *   - After all assignments, UPDATE status to "Success"/"Failed"/"Partial Success"
 */
public with sharing class AttendeeProcessingLogger {
  // ─── INPUT WRAPPER ───
  public class ProcessingLogInput {
    @InvocableVariable(label='Opportunity ID' required=true)
    public Id opportunityId;

    @InvocableVariable(
      label='Processing Type'
      description='Outbound Email, Inbound Reply, Manual Reprocess'
    )
    public String processingType;

    @InvocableVariable(
      label='Status'
      description='In Progress, Success, Partial Success, Failed'
    )
    public String status;

    @InvocableVariable(
      label='Inbound Email Message ID'
      description='18-char ID of the incoming EmailMessage'
    )
    public String emailMessageId;

    @InvocableVariable(
      label='Outgoing Email Message ID'
      description='18-char ID of the original outgoing EmailMessage'
    )
    public String outgoingEmailId;

    @InvocableVariable(label='Sender Email')
    public String senderEmail;

    @InvocableVariable(label='Sender Name')
    public String senderName;

    @InvocableVariable(label='Total Registration Products')
    public Decimal totalRegistrationProducts;

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

    @InvocableVariable(
      label='Error Category'
      description='Validation Rule, JSON Parse, No Match, DML Error, None'
    )
    public String errorCategory;

    @InvocableVariable(label='Flow API Name')
    public String flowApiName;

    @InvocableVariable(label='Flow Interview GUID')
    public String flowInterviewGuid;
  }

  // ─── OUTPUT WRAPPER ───
  public class ProcessingLogOutput {
    @InvocableVariable(label='Processing Log ID')
    public Id processingLogId;

    @InvocableVariable(label='Processing Log Name (e.g. APL-0001)')
    public String processingLogName;

    @InvocableVariable(label='Success')
    public Boolean success;

    @InvocableVariable(label='Error Message')
    public String errorMessage;
  }

  @InvocableMethod(
    label='Create Attendee Processing Log'
    description='Creates a processing log record to track attendee collection flow activity. Returns the log ID for linking assignment details.'
    category='Attendee Processing'
  )
  public static List<ProcessingLogOutput> createProcessingLog(
    List<ProcessingLogInput> inputs
  ) {
    List<ProcessingLogOutput> outputs = new List<ProcessingLogOutput>();

    for (ProcessingLogInput input : inputs) {
      ProcessingLogOutput output = new ProcessingLogOutput();
      try {
        Attendee_Processing_Log__c log = new Attendee_Processing_Log__c();
        log.Opportunity__c = input.opportunityId;
        log.Processing_Type__c = input.processingType;
        log.Status__c = String.isNotBlank(input.status)
          ? input.status
          : 'In Progress';
        log.Processing_Date__c = Datetime.now();
        log.Email_Message_Id__c = input.emailMessageId;
        log.Outgoing_Email_Id__c = input.outgoingEmailId;
        log.Sender_Email__c = input.senderEmail;
        log.Sender_Name__c = input.senderName;
        log.Total_Registration_Products__c = input.totalRegistrationProducts;
        log.Attendees_Provided__c = input.attendeesProvided;
        log.Attendees_Assigned__c = input.attendeesAssigned;
        log.Attendees_Not_Assigned__c = input.attendeesNotAssigned;
        log.Open_Slots_Remaining__c = input.openSlotsRemaining;
        log.AI_Prompt_Input__c = input.aiPromptInput;
        log.AI_Raw_Response__c = input.aiRawResponse;
        log.AI_Model_Used__c = input.aiModelUsed;
        log.Error_Message__c = input.errorMessage;
        log.Error_Category__c = String.isNotBlank(input.errorCategory)
          ? input.errorCategory
          : 'None';
        log.Flow_API_Name__c = input.flowApiName;
        log.Flow_Interview_GUID__c = input.flowInterviewGuid;

        insert log;

        output.processingLogId = log.Id;
        output.processingLogName = log.Name;
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
