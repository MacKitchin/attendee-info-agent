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
      results.add(buildSingle(req));
    }

    return results;
  }

  private static Result buildSingle(Request req) {
    Result res = new Result();

    // Header — always present
    String header =
      'Opportunity: ' +
      req.opportunityName +
      '\n' +
      'Overall Status: ' +
      req.statusMessage;

    // If no log ID, return minimal context
    if (String.isBlank(req.processingLogId)) {
      res.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return res;
    }

    Id logId;
    try {
      logId = Id.valueOf(req.processingLogId);
    } catch (Exception e) {
      res.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return res;
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
      res.formattedContext =
        header +
        '\n\nNo detailed assignment records are available for this run.';
      return res;
    }

    // Build assigned lines
    List<String> assignedLines = new List<String>();
    if (!assigned.isEmpty()) {
      assignedLines.add('\nASSIGNED ATTENDEES:');
      Integer idx = 1;
      for (Attendee_Assignment_Detail__c d : assigned) {
        assignedLines.add(formatAssignedLine(idx, d));
        idx++;
      }
    }

    // Build failed/skipped lines
    List<String> failedLines = new List<String>();
    if (!failedSkipped.isEmpty()) {
      failedLines.add('\nFAILED / SKIPPED ATTENDEES:');
      Integer idx = 1;
      for (Attendee_Assignment_Detail__c d : failedSkipped) {
        failedLines.add(formatFailedLine(idx, d));
        idx++;
      }
    }

    // Assemble and truncate if needed
    res.formattedContext = assembleWithTruncation(
      header,
      assignedLines,
      failedLines
    );
    return res;
  }

  private static String formatAssignedLine(
    Integer idx,
    Attendee_Assignment_Detail__c d
  ) {
    return idx +
      '. ' +
      safeStr(d.Extracted_Name__c) +
      ' (' +
      safeStr(d.Extracted_Email__c) +
      ')' +
      ' \u2014 Event: ' +
      safeStr(d.Event_Name__c) +
      ' | Product: ' +
      safeStr(d.Product_Type__c);
  }

  private static String formatFailedLine(
    Integer idx,
    Attendee_Assignment_Detail__c d
  ) {
    String line =
      idx +
      '. ' +
      safeStr(d.Extracted_Name__c) +
      ' (' +
      safeStr(d.Extracted_Email__c) +
      ')' +
      ' \u2014 Event: ' +
      safeStr(d.Event_Name__c) +
      ' | Product: ' +
      safeStr(d.Product_Type__c);
    if (String.isNotBlank(d.Assignment_Error__c)) {
      line += '\n   Reason: ' + d.Assignment_Error__c;
    }
    return line;
  }

  private static String safeStr(String val) {
    return String.isBlank(val) ? '' : val;
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
    String full = header;
    for (String line : assignedLines) {
      full += '\n' + line;
    }
    for (String line : failedLines) {
      full += '\n' + line;
    }

    if (full.length() <= MAX_LENGTH) {
      return full;
    }

    // Truncation needed — remove lines from middle of failed section first,
    // then assigned section. Always keep header + section headers + first entry.

    // Try removing failed lines from middle first
    List<String> trimmedFailed = truncateSection(failedLines);
    String attempt = buildOutput(header, assignedLines, trimmedFailed);
    if (attempt.length() <= MAX_LENGTH) {
      return attempt;
    }

    // Still too long — also truncate assigned section
    List<String> trimmedAssigned = truncateSection(assignedLines);
    attempt = buildOutput(header, trimmedAssigned, trimmedFailed);
    if (attempt.length() <= MAX_LENGTH) {
      return attempt;
    }

    // Last resort — hard truncate
    return attempt.substring(0, MAX_LENGTH - TRUNCATION_MARKER.length()) +
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

  private static String buildOutput(
    String header,
    List<String> assignedLines,
    List<String> failedLines
  ) {
    String output = header;
    for (String line : assignedLines) {
      output += '\n' + line;
    }
    for (String line : failedLines) {
      output += '\n' + line;
    }
    output += TRUNCATION_MARKER;
    return output;
  }
}
