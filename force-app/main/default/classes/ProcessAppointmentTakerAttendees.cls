/**
 * @description Invocable Apex to process registration attendees from JSON and assign to available OpportunityLineItems.
 * Attendees are matched to OLIs by event_name + product_type (group-fill). If no match, falls back to
 * the next available open slot in creation order.
 * @author Agentforce
 * @group Attendee Processing
 * @date 2026-02-10
 * @modified 2026-02-19 — Added group-fill assignment by Event Name + Product Type
 * @modified 2026-02-24 — Added Event_Attendee_Contact__c Contact lookup by attendee email + Opportunity AccountId
 */
public with sharing class ProcessAppointmentTakerAttendees {
  /**
   * @description Request wrapper for invocable method
   */
  public class Request {
    @InvocableVariable(required=true)
    public String jsonString;
    @InvocableVariable(required=true)
    public String opportunityId;
    @InvocableVariable
    public Id processingLogId;
  }

  /**
   * @description Result wrapper for invocable method
   */
  public class Result {
    @InvocableVariable
    public Boolean isSuccess;
    @InvocableVariable
    public String statusMessage;
    @InvocableVariable
    public Integer attendeesProvided;
    @InvocableVariable
    public Integer attendeesAssigned;
    @InvocableVariable
    public Integer attendeesNotAssigned;
    @InvocableVariable
    public Integer openSlotsRemaining;
    @InvocableVariable
    public String finalStatus;
    @InvocableVariable
    public String errorCategory;

    public Result(Boolean isSuccess, String statusMessage) {
      this(isSuccess, statusMessage, null, null, null, null, null, null);
    }

    public Result(
      Boolean isSuccess,
      String statusMessage,
      Integer attendeesProvided,
      Integer attendeesAssigned,
      Integer attendeesNotAssigned,
      Integer openSlotsRemaining,
      String finalStatus,
      String errorCategory
    ) {
      this.isSuccess = isSuccess;
      this.statusMessage = statusMessage;
      this.attendeesProvided = attendeesProvided;
      this.attendeesAssigned = attendeesAssigned;
      this.attendeesNotAssigned = attendeesNotAssigned;
      this.openSlotsRemaining = openSlotsRemaining;
      this.finalStatus = finalStatus;
      this.errorCategory = errorCategory;
    }
  }

  private class AssignmentAttempt {
    Attendee attendee;
    OpportunityLineItem target;
    Id assignedContactId;

    AssignmentAttempt(
      Attendee attendee,
      OpportunityLineItem target,
      Id assignedContactId
    ) {
      this.attendee = attendee;
      this.target = target;
      this.assignedContactId = assignedContactId;
    }
  }

  // Enum for status fragments (follow ALL_CAPS_SNAKE_CASE)
  public enum STATUS_PART {
    INVALID_JSON,
    NO_ATTENDEES_PROVIDED,
    NO_MATCHING_LINE_ITEMS,
    SUCCESS_ASSIGNED,
    PARTIAL_ASSIGNED,
    ERROR
  }

  private static final Set<Id> SUPPORTED_PRODUCT_IDS = new Set<Id>{
    '01t4X000004U13iQAC', // Appointment Taker
    '01t4X000004U14AQAS', // Non-Appointment Taker
    '01t4X000004U148QAC' // Marketer
  };
  @TestVisible
  private static final Set<String> TEST_FALLBACK_PRODUCT_NAMES = new Set<String>{
    'Appointment Taker',
    'Non-Appointment Taker',
    'Marketer'
  };

  /**
   * @description Invocable entry point to process attendees for supported registration OLIs on an Opportunity.
   * Accepts a list to support Flow bulkification; each request is processed independently.
   * @param requests List of Request containing jsonString (array of attendees) and opportunityId
   * @return List of Result containing isSuccess and statusMessage
   */
  @InvocableMethod(
    label='Process Appointment Taker Attendees'
    description='Maps attendees from JSON to empty supported registration line items on the given Opportunity.'
  )
  public static List<Result> process(List<Request> requests) {
    List<Result> results = new List<Result>();
    if (requests == null || requests.isEmpty()) {
      results.add(
        new Result(
          true,
          buildStatus(
            STATUS_PART.NO_ATTENDEES_PROVIDED,
            'No requests to process.'
          )
        )
      );
      return results;
    }

    // Process each request independently to avoid cross-opportunity data leakage
    for (Request req : requests) {
      results.add(processSingle(req));
    }
    return results;
  }

  /**
   * @description Process a single request payload.
   */
  private static Result processSingle(Request req) {
    // Early validations
    if (req == null) {
      return new Result(false, buildStatus(STATUS_PART.ERROR, 'Null request.'));
    }
    if (String.isBlank(req.opportunityId)) {
      return new Result(
        false,
        buildStatus(STATUS_PART.ERROR, 'opportunityId is required.')
      );
    }
    if (String.isBlank(req.jsonString)) {
      // Treat missing attendees as a no-op success
      return new Result(
        true,
        buildStatus(STATUS_PART.NO_ATTENDEES_PROVIDED, 'Empty jsonString.'),
        0,
        0,
        0,
        0,
        'Failed',
        'AI Extraction'
      );
    }

    // Parse and validate JSON
    List<Attendee> attendees;
    try {
      attendees = parseAttendees(req.jsonString);
    } catch (ProcessException pe) {
      return new Result(
        false,
        buildStatus(STATUS_PART.INVALID_JSON, pe.getMessage()),
        0,
        0,
        0,
        0,
        'Failed',
        'JSON Parse'
      );
    } catch (Exception e) {
      return new Result(
        false,
        buildStatus(
          STATUS_PART.INVALID_JSON,
          'Unexpected error parsing JSON: ' + e.getMessage()
        ),
        0,
        0,
        0,
        0,
        'Failed',
        'JSON Parse'
      );
    }

    if (attendees.isEmpty()) {
      return new Result(
        true,
        buildStatus(
          STATUS_PART.NO_ATTENDEES_PROVIDED,
          'No attendees found in jsonString.'
        ),
        0,
        0,
        0,
        0,
        'Failed',
        'AI Extraction'
      );
    }

    // Load available OLIs (WITH USER_MODE to enforce user security)
    List<OpportunityLineItem> available = loadAvailableOlis(req.opportunityId);

    if (available.isEmpty()) {
      return new Result(
        true,
        buildStatus(
          STATUS_PART.NO_MATCHING_LINE_ITEMS,
          'No open supported registration line items found.'
        ),
        attendees.size(),
        0,
        attendees.size(),
        0,
        'Failed',
        'Other'
      );
    }

    // Resolve Opportunity AccountId for Contact matching
    List<Opportunity> opps = [
      SELECT AccountId
      FROM Opportunity
      WHERE Id = :req.opportunityId
      WITH USER_MODE
      LIMIT 1
    ];
    Id accountId = (!opps.isEmpty()) ? opps[0].AccountId : null;

    // Bulk-resolve attendee emails to Contact Ids on the Opportunity's Account
    Map<String, Id> emailToContactId = new Map<String, Id>();
    if (accountId != null) {
      Set<String> attendeeEmails = new Set<String>();
      for (Attendee a : attendees) {
        if (String.isNotBlank(a.email)) {
          attendeeEmails.add(a.email.toLowerCase());
        }
      }
      if (!attendeeEmails.isEmpty()) {
        for (Contact c : [
          SELECT Id, Email
          FROM Contact
          WHERE Email IN :attendeeEmails AND AccountId = :accountId
          WITH USER_MODE
        ]) {
          // First match wins; if duplicates exist on the Account the earliest-inserted wins
          String key = c.Email.toLowerCase();
          if (!emailToContactId.containsKey(key)) {
            emailToContactId.put(key, c.Id);
          }
        }
      }
    }

    // Build group map: "eventName|productType" -> ordered queue of open OLIs
    // OLIs within each group are served in CreatedDate ASC order (from the query above).
    Map<String, List<OpportunityLineItem>> groupMap = new Map<String, List<OpportunityLineItem>>();
    for (OpportunityLineItem oli : available) {
      String key = buildGroupKey(oli.Event_Name__c, oli.Product_Type__c);
      if (!groupMap.containsKey(key)) {
        groupMap.put(key, new List<OpportunityLineItem>());
      }
      groupMap.get(key).add(oli);
    }

    // Track claimed slot IDs to avoid double-assignment
    Set<Id> claimed = new Set<Id>();
    List<OpportunityLineItem> toUpdate = new List<OpportunityLineItem>();
    List<AssignmentAttempt> attemptedAssignments = new List<AssignmentAttempt>();
    List<AssignmentAttempt> skippedAssignments = new List<AssignmentAttempt>();

    for (Attendee a : attendees) {
      if (toUpdate.size() >= available.size())
        break;

      OpportunityLineItem target = null;

      // 1. Try matching group by event_name + product_type
      if (String.isNotBlank(a.eventName) && String.isNotBlank(a.productType)) {
        String key = buildGroupKey(a.eventName, a.productType);
        if (groupMap.containsKey(key)) {
          for (OpportunityLineItem oli : groupMap.get(key)) {
            if (!claimed.contains(oli.Id)) {
              target = oli;
              break;
            }
          }
        }
      }

      // 2. Fallback: next available unclaimed slot (positional)
      if (target == null) {
        for (OpportunityLineItem oli : available) {
          if (!claimed.contains(oli.Id)) {
            target = oli;
            break;
          }
        }
      }

      if (target != null) {
        claimed.add(target.Id);
        Id assignedContactId = null;
        if (String.isNotBlank(a.email)) {
          assignedContactId = emailToContactId.get(a.email.toLowerCase());
        }

        attemptedAssignments.add(
          new AssignmentAttempt(a, target, assignedContactId)
        );

        // Build clean SObject to avoid USER_MODE FLS errors on relationship fields
        OpportunityLineItem upd = new OpportunityLineItem(Id = target.Id);
        upd.Attendee_First_Name__c = a.firstName;
        upd.Attendee_Name__c =
          a.firstName + (String.isNotBlank(a.lastName) ? ' ' + a.lastName : '');
        upd.Attendee_Email__c = a.email;

        // Populate Event Attendee Contact lookup
        if (assignedContactId != null) {
          upd.Event_Attendee_Contact__c = assignedContactId;
        }
        toUpdate.add(upd);
      } else {
        skippedAssignments.add(new AssignmentAttempt(a, null, null));
      }
    }

    for (Integer i = toUpdate.size(); i < attendees.size(); i++) {
      skippedAssignments.add(new AssignmentAttempt(attendees[i], null, null));
    }

    if (toUpdate.isEmpty()) {
      // Should not happen due to earlier checks, but guard anyway
      return new Result(
        true,
        buildStatus(STATUS_PART.NO_MATCHING_LINE_ITEMS, 'No slots updated.'),
        attendees.size(),
        0,
        attendees.size(),
        available.size(),
        'Failed',
        'Other'
      );
    }

    // Bulk update with SYSTEM_MODE so all custom fields (e.g. Attendee_Name__c)
    // are written regardless of FLS for the automated process running user.
    // SOQL above uses USER_MODE to enforce read security on the query.
    Database.SaveResult[] srList = Database.update(
      toUpdate,
      false,
      AccessLevel.SYSTEM_MODE
    );

    // Compute result counts and message
    Integer successCount = 0;
    List<String> errs = new List<String>();
    for (Integer i = 0; i < srList.size(); i++) {
      if (srList[i].isSuccess()) {
        successCount++;
      } else {
        for (Database.Error e : srList[i].getErrors()) {
          errs.add(
            'OLI ' +
              toUpdate[i].Id +
              ': ' +
              e.getStatusCode() +
              ' - ' +
              e.getMessage()
          );
        }
      }
    }

    Integer unassignedFromCapacity = available.size() - successCount;
    Integer unassignedFromDemand = Math.max(0, attendees.size() - successCount);
    // prefer attendee-centric unassigned count for clarity
    Integer notAssigned = unassignedFromDemand;
    Integer openSlotsRemaining = Math.max(0, available.size() - successCount);
    String errorCategory = classifyProcessingError(errs);

    String detail =
      'Attendees provided=' +
      attendees.size() +
      ', assigned=' +
      successCount +
      ', notAssigned=' +
      notAssigned +
      ', openSlots=' +
      openSlotsRemaining;

    if (!errs.isEmpty()) {
      detail += '. Errors: ' + String.join(errs, ' | ');
    }

    logAssignmentDetails(
      req.processingLogId,
      attemptedAssignments,
      skippedAssignments,
      srList
    );

    if (successCount == attendees.size()) {
      return new Result(
        true,
        buildStatus(STATUS_PART.SUCCESS_ASSIGNED, detail),
        attendees.size(),
        successCount,
        notAssigned,
        openSlotsRemaining,
        'Success',
        'None'
      );
    } else if (successCount > 0) {
      return new Result(
        true,
        buildStatus(STATUS_PART.PARTIAL_ASSIGNED, detail),
        attendees.size(),
        successCount,
        notAssigned,
        openSlotsRemaining,
        'Partial Success',
        errorCategory
      );
    } else {
      return new Result(
        false,
        buildStatus(STATUS_PART.ERROR, detail),
        attendees.size(),
        successCount,
        notAssigned,
        openSlotsRemaining,
        'Failed',
        errorCategory
      );
    }
  }

  /**
   * @description Helper to build a consistent status message
   */
  private static String buildStatus(STATUS_PART part, String message) {
    return String.valueOf(part) + ': ' + (message == null ? '' : message);
  }

  /**
   * @description Loads open OLIs for supported attendee-registration products.
   * Uses a test-only name fallback so unit tests do not depend on fixed org IDs.
   */
  private static List<OpportunityLineItem> loadAvailableOlis(
    String opportunityId
  ) {
    if (Test.isRunningTest()) {
      return [
        SELECT
          Id,
          OpportunityId,
          Product2.Name,
          CreatedDate,
          Event_Name__c,
          Product_Type__c,
          Attendee_First_Name__c,
          Attendee_Name__c,
          Attendee_Email__c,
          Event_Attendee_Contact__c
        FROM OpportunityLineItem
        WHERE
          OpportunityId = :opportunityId
          AND (Product2Id IN :SUPPORTED_PRODUCT_IDS
          OR Product2.Name IN :TEST_FALLBACK_PRODUCT_NAMES)
          AND Attendee_Name__c = NULL
          AND Attendee_Email__c = NULL
        WITH USER_MODE
        ORDER BY CreatedDate ASC
      ];
    }

    return [
      SELECT
        Id,
        OpportunityId,
        Product2.Name,
        CreatedDate,
        Event_Name__c,
        Product_Type__c,
        Attendee_First_Name__c,
        Attendee_Name__c,
        Attendee_Email__c,
        Event_Attendee_Contact__c
      FROM OpportunityLineItem
      WHERE
        OpportunityId = :opportunityId
        AND Product2Id IN :SUPPORTED_PRODUCT_IDS
        AND Attendee_Name__c = NULL
        AND Attendee_Email__c = NULL
      WITH USER_MODE
      ORDER BY CreatedDate ASC
    ];
  }

  /**
   * @description Builds a lowercase composite key for group-fill matching.
   * Normalises nulls to empty string so null|null still forms a valid key.
   */
  @TestVisible
  private static String buildGroupKey(String eventName, String productType) {
    return (String.isNotBlank(eventName)
        ? eventName.trim().toLowerCase()
        : '') +
      '|' +
      (String.isNotBlank(productType) ? productType.trim().toLowerCase() : '');
  }

  /**
   * @description Lightweight attendee DTO
   */
  private class Attendee {
    String firstName;
    String lastName;
    String email;
    String eventName; // from event_name JSON key
    String productType; // from product_type JSON key

    Attendee(
      String firstName,
      String lastName,
      String email,
      String eventName,
      String productType
    ) {
      this.firstName = firstName;
      this.lastName = lastName;
      this.email = email;
      this.eventName = eventName;
      this.productType = productType;
    }
  }

  /**
   * @description Custom exception for processing errors
   */
  private class ProcessException extends Exception {
  }

  private static void logAssignmentDetails(
    Id processingLogId,
    List<AssignmentAttempt> attemptedAssignments,
    List<AssignmentAttempt> skippedAssignments,
    Database.SaveResult[] srList
  ) {
    if (processingLogId == null) {
      return;
    }

    List<AttendeeAssignmentDetailLogger.AssignmentDetailInput> inputs = new List<AttendeeAssignmentDetailLogger.AssignmentDetailInput>();

    for (Integer i = 0; i < attemptedAssignments.size(); i++) {
      AssignmentAttempt attempt = attemptedAssignments[i];
      AttendeeAssignmentDetailLogger.AssignmentDetailInput input = new AttendeeAssignmentDetailLogger.AssignmentDetailInput();
      input.processingLogId = processingLogId;
      input.opportunityProductId = attempt.target.Id;
      input.productName = attempt.target.Product2.Name;
      input.productType = attempt.target.Product_Type__c;
      input.eventName = attempt.target.Event_Name__c;
      input.extractedName = buildAttendeeName(attempt.attendee);
      input.extractedEmail = attempt.attendee.email;
      input.assignedContactId = attempt.assignedContactId;
      input.previousAttendeeName = attempt.target.Attendee_Name__c;
      input.previousAttendeeEmail = attempt.target.Attendee_Email__c;
      input.previousContactId = attempt.target.Event_Attendee_Contact__c;

      if (srList[i].isSuccess()) {
        input.assignmentStatus = 'Assigned';
      } else {
        input.assignmentStatus = 'Failed';
        input.assignmentError = extractSaveErrors(srList[i]);
      }
      inputs.add(input);
    }

    for (AssignmentAttempt attempt : skippedAssignments) {
      AttendeeAssignmentDetailLogger.AssignmentDetailInput input = new AttendeeAssignmentDetailLogger.AssignmentDetailInput();
      input.processingLogId = processingLogId;
      input.productType = attempt.attendee.productType;
      input.eventName = attempt.attendee.eventName;
      input.extractedName = buildAttendeeName(attempt.attendee);
      input.extractedEmail = attempt.attendee.email;
      input.assignmentStatus = 'Skipped';
      input.assignmentError = 'No available open registration slot for attendee.';
      inputs.add(input);
    }

    if (inputs.isEmpty()) {
      return;
    }

    try {
      AttendeeAssignmentDetailLogger.logAssignmentDetail(inputs);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to write attendee assignment detail logs: ' + e.getMessage()
      );
    }
  }

  private static String buildAttendeeName(Attendee attendee) {
    if (attendee == null) {
      return null;
    }

    String fullName = attendee.firstName;
    if (String.isNotBlank(attendee.lastName)) {
      fullName += ' ' + attendee.lastName;
    }
    return fullName;
  }

  private static String extractSaveErrors(Database.SaveResult saveResult) {
    List<String> messages = new List<String>();
    for (Database.Error err : saveResult.getErrors()) {
      messages.add(err.getStatusCode() + ' - ' + err.getMessage());
    }
    return String.join(messages, ' | ');
  }

  private static String classifyProcessingError(List<String> errors) {
    if (errors == null || errors.isEmpty()) {
      return 'None';
    }

    for (String err : errors) {
      if (err.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
        return 'Validation';
      }
    }
    return 'DML';
  }

  /**
   * @description Parse attendees from a JSON array of objects.
   * Recognised keys: first_name, last_name, email, event_name, product_type
   * Uses JSON.deserializeUntyped to validate structure explicitly.
   */
  private static List<Attendee> parseAttendees(String jsonString) {
    Object root = JSON.deserializeUntyped(jsonString);
    if (!(root instanceof List<Object>)) {
      throw new ProcessException('JSON must be an array.');
    }
    List<Object> rawList = (List<Object>) root;
    List<Attendee> out = new List<Attendee>();
    for (Object row : rawList) {
      if (!(row instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> m = (Map<String, Object>) row;
      String fn = (m.containsKey('first_name') && m.get('first_name') != null)
        ? String.valueOf(m.get('first_name')).trim()
        : null;
      String ln = (m.containsKey('last_name') && m.get('last_name') != null)
        ? String.valueOf(m.get('last_name')).trim()
        : null;
      String em = (m.containsKey('email') && m.get('email') != null)
        ? String.valueOf(m.get('email')).trim()
        : null;
      String ev = (m.containsKey('event_name') && m.get('event_name') != null)
        ? String.valueOf(m.get('event_name')).trim()
        : null;
      String pt = (m.containsKey('product_type') &&
        m.get('product_type') != null)
        ? String.valueOf(m.get('product_type')).trim()
        : null;

      // Require at minimum email and first name; allow empty last name
      if (String.isBlank(fn) || String.isBlank(em)) {
        continue;
      }
      if (ln == null)
        ln = '';
      out.add(new Attendee(fn, ln, em, ev, pt));
    }
    return out;
  }
}
