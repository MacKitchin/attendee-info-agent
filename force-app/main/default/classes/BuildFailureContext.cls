/**
 * @description Invocable Apex that builds a formatted context string summarising
 *              attendee assignment results for a given processing log. Designed to
 *              feed into an AI prompt that drafts a Salesforce Task for follow-up.
 */
public with sharing class BuildFailureContext {
  private static final Integer MAX_LENGTH = 10000;
  private static final String TRUNCATION_MARKER = '\n[truncated — some records omitted]';

  // ─── INPUT WRAPPER ───
  public class Request {
    @InvocableVariable(
      label='Processing Log ID'
      description='ID of the Attendee_Processing_Log__c record. May be null or blank.'
    )
    public String processingLogId;

    @InvocableVariable(
      label='Status Message'
      required=true
      description='Overall status message from the processing run'
    )
    public String statusMessage;

    @InvocableVariable(
      label='Opportunity Name'
      required=true
      description='Name of the Opportunity being processed'
    )
    public String opportunityName;
  }

  // ─── OUTPUT WRAPPER ───
  public class Result {
    @InvocableVariable(label='Formatted Context')
    public String formattedContext;
  }

  @InvocableMethod(
    label='Build Failure Context'
    description='Queries assignment detail records and formats a context block for AI-generated task creation.'
    category='Attendee Processing'
  )
  public static List<Result> build(List<Request> requests) {
    List<Result> results = new List<Result>();

    for (Request req : requests) {
      results.add(buildContextForRequest(req));
    }

    return results;
  }

  private static Result buildContextForRequest(Request req) {
    Result contextResult = new Result();

    // Header — always present
    String header =
      'Opportunity: ' +
      req.opportunityName +
      '\n' +
      'Overall Status: ' +
      req.statusMessage;

    // If no log ID, return minimal context
    if (String.isBlank(req.processingLogId)) {
      contextResult.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return contextResult;
    }

    Id logId;
    try {
      logId = Id.valueOf(req.processingLogId);
    } catch (Exception e) {
      contextResult.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return contextResult;
    }

    // Query assigned records (SYSTEM_MODE — this runs as an automated backend
    // process triggered by email/Flow, so all users must be able to read all fields)
    List<Attendee_Assignment_Detail__c> assigned = [
      SELECT
        Extracted_Name__c,
        Extracted_Email__c,
        Event_Name__c,
        Product_Type__c
      FROM Attendee_Assignment_Detail__c
      WHERE
        Processing_Log__c = :logId
        AND Assignment_Status__c = 'Assigned'
      WITH SYSTEM_MODE
      ORDER BY Extracted_Name__c ASC
    ];

    // Query failed/skipped records (SYSTEM_MODE — consistent with above)
    List<Attendee_Assignment_Detail__c> failedSkipped = [
      SELECT
        Extracted_Name__c,
        Extracted_Email__c,
        Event_Name__c,
        Product_Type__c,
        Assignment_Error__c
      FROM Attendee_Assignment_Detail__c
      WHERE
        Processing_Log__c = :logId
        AND Assignment_Status__c IN ('Failed', 'Skipped')
      WITH SYSTEM_MODE
      ORDER BY Extracted_Name__c ASC
    ];

    // If no records at all, return minimal context
    if (assigned.isEmpty() && failedSkipped.isEmpty()) {
      contextResult.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return contextResult;
    }

    // Build assigned lines
    List<String> assignedLines = new List<String>();
    if (!assigned.isEmpty()) {
      assignedLines.add('\nASSIGNED ATTENDEES:');
      Integer lineNumber = 1;
      for (Attendee_Assignment_Detail__c detail : assigned) {
        assignedLines.add(formatAssignedLine(lineNumber, detail));
        lineNumber++;
      }
    }

    // Build failed/skipped lines
    List<String> failedLines = new List<String>();
    if (!failedSkipped.isEmpty()) {
      failedLines.add('\nFAILED / SKIPPED ATTENDEES:');
      Integer lineNumber = 1;
      for (Attendee_Assignment_Detail__c detail : failedSkipped) {
        failedLines.add(formatFailedLine(lineNumber, detail));
        lineNumber++;
      }
    }

    // Assemble and truncate if needed
    contextResult.formattedContext = assembleWithTruncation(
      header,
      assignedLines,
      failedLines
    );
    return contextResult;
  }

  private static String formatAssignedLine(
    Integer lineNumber,
    Attendee_Assignment_Detail__c detail
  ) {
    return lineNumber +
      '. ' +
      blankToEmpty(detail.Extracted_Name__c) +
      ' (' +
      blankToEmpty(detail.Extracted_Email__c) +
      ')' +
      ' \u2014 Event: ' +
      blankToEmpty(detail.Event_Name__c) +
      ' | Product: ' +
      blankToEmpty(detail.Product_Type__c);
  }

  private static String formatFailedLine(
    Integer lineNumber,
    Attendee_Assignment_Detail__c detail
  ) {
    String line =
      lineNumber +
      '. ' +
      blankToEmpty(detail.Extracted_Name__c) +
      ' (' +
      blankToEmpty(detail.Extracted_Email__c) +
      ')' +
      ' \u2014 Event: ' +
      blankToEmpty(detail.Event_Name__c) +
      ' | Product: ' +
      blankToEmpty(detail.Product_Type__c);
    if (String.isNotBlank(detail.Assignment_Error__c)) {
      line += '\n   Reason: ' + detail.Assignment_Error__c;
    }
    return line;
  }

  private static String blankToEmpty(String value) {
    return String.isBlank(value) ? '' : value;
  }

  /**
   * @description Assembles the full output, truncating from the middle of
   *              the failed section first, then assigned section, to stay
   *              within MAX_LENGTH. Always preserves header + first entry
   *              of each section.
   */
  private static String assembleWithTruncation(
    String header,
    List<String> assignedLines,
    List<String> failedLines
  ) {
    String assembledContext = header;
    for (String line : assignedLines) {
      assembledContext += '\n' + line;
    }
    for (String line : failedLines) {
      assembledContext += '\n' + line;
    }

    if (assembledContext.length() <= MAX_LENGTH) {
      return assembledContext;
    }

    // Truncation needed — remove lines from middle of failed section first,
    // then assigned section. Always keep header + section headers + first entry.

    // Try removing failed lines from middle first
    List<String> truncatedFailedLines = truncateSection(failedLines);
    String truncatedContext = joinSectionsWithTruncationMarker(header, assignedLines, truncatedFailedLines);
    if (truncatedContext.length() <= MAX_LENGTH) {
      return truncatedContext;
    }

    // Still too long — also truncate assigned section
    List<String> truncatedAssignedLines = truncateSection(assignedLines);
    truncatedContext = joinSectionsWithTruncationMarker(header, truncatedAssignedLines, truncatedFailedLines);
    if (truncatedContext.length() <= MAX_LENGTH) {
      return truncatedContext;
    }

    // Last resort — hard truncate
    return truncatedContext.substring(0, MAX_LENGTH - TRUNCATION_MARKER.length()) +
      TRUNCATION_MARKER;
  }

  /**
   * @description Keeps only the section header and first entry, discarding
   *              the rest of the section lines.
   */
  private static List<String> truncateSection(List<String> sectionLines) {
    if (sectionLines.size() <= 2) {
      return sectionLines;
    }
    // Keep header (index 0) and first entry (index 1)
    return new List<String>{ sectionLines[0], sectionLines[1] };
  }

  private static String joinSectionsWithTruncationMarker(
    String header,
    List<String> assignedLines,
    List<String> failedLines
  ) {
    String assembledOutput = header;
    for (String line : assignedLines) {
      assembledOutput += '\n' + line;
    }
    for (String line : failedLines) {
      assembledOutput += '\n' + line;
    }
    assembledOutput += TRUNCATION_MARKER;
    return assembledOutput;
  }
}
