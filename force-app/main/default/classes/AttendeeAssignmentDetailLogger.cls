/**
 * AttendeeAssignmentDetailLogger
 *
 * Invocable Apex class that Flows call to create Attendee_Assignment_Detail__c records.
 * Shows up in Flow Builder as an "Action" element: "Log Attendee Assignment Detail"
 *
 * USAGE IN FLOW BUILDER:
 * ─────────────────────
 * 1. Open your Flow (Event_Registration_Process_Attendee_Reply)
 * 2. INSIDE your OLI assignment loop, add an "Action" element
 * 3. Search for "Log Attendee Assignment Detail"
 * 4. Map: processingLogId = the ID returned by AttendeeProcessingLogger
 * 5. Map the OLI fields, extracted attendee data, and assignment result
 *
 * CAPTURING "BEFORE" STATE:
 *   Before your Flow updates an OLI with new attendee info, read the OLI's
 *   current Attendee_Name__c, Attendee_Email__c, and Event_Attendee_Contact__c
 *   into variables, then pass them as previousAttendeeName, previousAttendeeEmail,
 *   and previousContactId. This creates a full audit trail of overwrites.
 *
 * HANDLING FAILURES:
 *   If the OLI update fails (e.g., validation rule), still call this logger
 *   with assignmentStatus = "Failed" and assignmentError = the error message.
 *   This ensures every attempt is tracked, not just successes.
 */
public with sharing class AttendeeAssignmentDetailLogger {
  // ─── INPUT WRAPPER ───
  public class AssignmentDetailInput {
    @InvocableVariable(
      label='Processing Log ID'
      required=true
      description='ID from AttendeeProcessingLogger output'
    )
    public Id processingLogId;

    @InvocableVariable(label='Opportunity Product (OLI) ID')
    public Id opportunityProductId;

    @InvocableVariable(label='Product Name')
    public String productName;

    @InvocableVariable(
      label='Product Type'
      description='Appointment Taker, Non-Appointment Taker, Marketer'
    )
    public String productType;

    @InvocableVariable(label='Event Name')
    public String eventName;

    @InvocableVariable(
      label='Extracted Name'
      description='Attendee name extracted by AI from the reply'
    )
    public String extractedName;

    @InvocableVariable(
      label='Extracted Email'
      description='Attendee email extracted by AI'
    )
    public String extractedEmail;

    @InvocableVariable(
      label='Extracted Phone'
      description='Attendee phone extracted by AI'
    )
    public String extractedPhone;

    @InvocableVariable(
      label='Assigned Contact ID'
      description='The Contact record matched/created for this attendee'
    )
    public Id assignedContactId;

    @InvocableVariable(
      label='Assignment Status'
      description='Assigned, Failed, Skipped (TBD), Skipped (Already Filled)'
    )
    public String assignmentStatus;

    @InvocableVariable(
      label='Assignment Error'
      description='Error message if assignment failed'
    )
    public String assignmentError;

    @InvocableVariable(
      label='Previous Attendee Name'
      description='Name that was on the OLI before this update'
    )
    public String previousAttendeeName;

    @InvocableVariable(
      label='Previous Attendee Email'
      description='Email that was on the OLI before this update'
    )
    public String previousAttendeeEmail;

    @InvocableVariable(
      label='Previous Contact ID'
      description='Contact that was linked to the OLI before this update'
    )
    public Id previousContactId;
  }

  // ─── OUTPUT WRAPPER ───
  public class AssignmentDetailOutput {
    @InvocableVariable(label='Assignment Detail ID')
    public Id assignmentDetailId;

    @InvocableVariable(label='Assignment Detail Name (e.g. AAD-0001)')
    public String assignmentDetailName;

    @InvocableVariable(label='Success')
    public Boolean success;

    @InvocableVariable(label='Error Message')
    public String errorMessage;
  }

  @InvocableMethod(
    label='Log Attendee Assignment Detail'
    description='Creates an assignment detail record for a single OLI attendee assignment attempt. Call once per OLI inside your processing loop.'
    category='Attendee Processing'
  )
  public static List<AssignmentDetailOutput> logAssignmentDetail(
    List<AssignmentDetailInput> inputs
  ) {
    List<AssignmentDetailOutput> outputs = new List<AssignmentDetailOutput>();

    for (AssignmentDetailInput input : inputs) {
      AssignmentDetailOutput output = new AssignmentDetailOutput();
      try {
        Attendee_Assignment_Detail__c detail = new Attendee_Assignment_Detail__c();
        detail.Processing_Log__c = input.processingLogId;
        detail.Opportunity_Product__c = input.opportunityProductId;
        detail.Product_Name__c = input.productName;
        detail.Product_Type__c = input.productType;
        detail.Event_Name__c = input.eventName;
        detail.Extracted_Name__c = input.extractedName;
        detail.Extracted_Email__c = input.extractedEmail;
        detail.Extracted_Phone__c = input.extractedPhone;
        detail.Assigned_Contact__c = input.assignedContactId;
        detail.Assignment_Status__c = String.isNotBlank(input.assignmentStatus)
          ? input.assignmentStatus
          : 'Assigned';
        detail.Assignment_Error__c = input.assignmentError;
        detail.Previous_Attendee_Name__c = input.previousAttendeeName;
        detail.Previous_Attendee_Email__c = input.previousAttendeeEmail;
        detail.Previous_Contact__c = input.previousContactId;

        insert detail;

        output.assignmentDetailId = detail.Id;
        output.assignmentDetailName = detail.Name;
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
