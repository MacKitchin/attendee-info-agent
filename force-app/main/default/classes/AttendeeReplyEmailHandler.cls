/**
 * @description Inbound Email Handler for attendee registration replies.
 * Receives emails forwarded from production@connectmeetings.com via an Email Service,
 * matches the reply to the original outgoing registration email, and inserts an
 * incoming EmailMessage linked to the related Opportunity. This triggers Flow B
 * (Event Registration - Process Attendee Reply) to extract and assign attendees.
 * @author Agentforce
 * @group Attendee Processing
 * @date 2026-02-11
 */
public class AttendeeReplyEmailHandler implements Messaging.InboundEmailHandler {
  @TestVisible
  private static final String SUBJECT_PATTERN = 'Action Required: Attendee Details for your Event Registrations';
  @TestVisible
  private static final Pattern REG_TOKEN_PATTERN = Pattern.compile(
    '(?i)\\[REG:([a-zA-Z0-9]{15,18})\\]'
  );
  @TestVisible
  private static final String OUTLOOK_REPLY_SEPARATOR = '________________________________';
  @TestVisible
  private static final String ORIGINAL_MESSAGE_SEPARATOR = '-----Original Message-----';
  private static final Pattern SEE_BELOW_PATTERN = Pattern.compile(
    '(?i)\\b(please\\s+see\\s+below|see\\s+below|details\\s+below|filled\\s+below|completed\\s+below|populated\\s+below)\\b'
  );
  private static final Pattern EMAIL_PATTERN = Pattern.compile(
    '(?i)\\b[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}\\b'
  );
  private static final Integer MAX_PROMPT_BODY_CHARS = 28000;
  private static final Integer LEGACY_LOOKBACK_DAYS = 60;

  /**
   * @description Handles an inbound email. If the subject matches the registration
   * pattern, queries for the original outgoing EmailMessage to find the related
   * Opportunity, then inserts a new incoming EmailMessage linked to that Opportunity.
   * @param email The inbound email
   * @param envelope The inbound email envelope
   * @return Messaging.InboundEmailResult indicating success or failure
   */
  public Messaging.InboundEmailResult handleInboundEmail(
    Messaging.InboundEmail email,
    Messaging.InboundEnvelope envelope
  ) {
    Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

    try {
      String subject = email.subject != null ? email.subject : '';

      // Only process replies to our registration emails; silently accept others
      if (!subject.containsIgnoreCase(SUBJECT_PATTERN)) {
        result.success = true;
        return result;
      }

      String fromAddr = normalizeEmail(email.fromAddress);
      if (String.isBlank(fromAddr)) {
        result.success = false;
        result.message = 'Sender email is missing on inbound message.';
        return result;
      }

      // Build a prompt-safe body:
      // - keep top reply when it contains attendee data
      // - if the signer says "see below", keep quoted/original content instead
      // - decode Outlook entities and cap body length for prompt stability
      String plainBody = preparePromptBody(email.plainTextBody);

      Id opportunityId;
      Id replyToEmailMessageId;

      // Preferred route: deterministic token in subject, e.g. [REG:006...]
      Id tokenOpportunityId = extractOpportunityIdFromSubject(subject);
      if (tokenOpportunityId != null) {
        EmailMessage tokenMatch = findOutgoingByTokenAndSender(
          tokenOpportunityId,
          fromAddr
        );
        if (tokenMatch == null) {
          result.success = false;
          result.message = 'Registration token found, but sender does not match the expected recipient email or recipient domain.';
          return result;
        }
        opportunityId = tokenOpportunityId;
        replyToEmailMessageId = tokenMatch.Id;
      } else {
        // Backward-compatible fallback for legacy emails without token
        EmailMessage legacyMatch = findLegacyOutgoingBySender(fromAddr);
        if (legacyMatch == null) {
          result.success = false;
          result.message =
            'No matching outgoing registration email found for: ' + fromAddr;
          return result;
        }
        opportunityId = legacyMatch.RelatedToId;
        replyToEmailMessageId = legacyMatch.Id;
      }

      // Build and insert the incoming EmailMessage linked to the Opportunity.
      // This insert triggers Flow B (Event Registration - Process Attendee Reply).
      EmailMessage em = new EmailMessage();
      em.Subject = subject;
      em.TextBody = plainBody; // prompt-safe body prepared from the inbound reply
      em.HtmlBody = null; // omit HTML; prompt template uses TextBody only
      em.FromAddress = fromAddr;
      em.FromName = email.fromName;
      em.ToAddress = email.toAddresses != null
        ? String.join(email.toAddresses, '; ')
        : '';
      em.Incoming = true;
      em.Status = '0'; // New
      em.MessageDate = System.now();
      em.RelatedToId = opportunityId;
      em.ReplyToEmailMessageId = replyToEmailMessageId;

      insert em;

      result.success = true;
    } catch (Exception e) {
      result.success = false;
      result.message = 'Error processing attendee reply: ' + e.getMessage();
    }

    return result;
  }

  @TestVisible
  private static String preparePromptBody(String rawBody) {
    String body = rawBody != null ? rawBody.trim() : '';
    if (String.isBlank(body)) {
      return '';
    }

    // Find the earliest reply separator: Outlook underscores or -----Original Message-----
    Integer outlookIdx = body.indexOf(OUTLOOK_REPLY_SEPARATOR);
    Integer origMsgIdx = body.indexOf(ORIGINAL_MESSAGE_SEPARATOR);

    Integer separatorIdx = -1;
    Integer separatorLen = 0;
    if (outlookIdx > 0 && (origMsgIdx <= 0 || outlookIdx <= origMsgIdx)) {
      separatorIdx = outlookIdx;
      separatorLen = OUTLOOK_REPLY_SEPARATOR.length();
    } else if (origMsgIdx > 0) {
      separatorIdx = origMsgIdx;
      separatorLen = ORIGINAL_MESSAGE_SEPARATOR.length();
    }

    if (separatorIdx > 0) {
      String topReply = body.substring(0, separatorIdx).trim();
      String quotedReply = body
        .substring(separatorIdx + separatorLen)
        .trim();

      // Preserve current behavior for normal replies, but recover attendee data
      // entered inside the quoted/original section (common "please see below").
      if (shouldKeepTopReplyOnly(topReply)) {
        body = topReply;
      } else if (hasAttendeeSignals(quotedReply)) {
        body = quotedReply;
      } else {
        body = topReply;
      }
    }

    body = decodeHtmlEntities(body);
    if (body.length() > MAX_PROMPT_BODY_CHARS) {
      body = body.substring(0, MAX_PROMPT_BODY_CHARS).trim();
    }
    return body;
  }

  @TestVisible
  private static Boolean shouldKeepTopReplyOnly(String topReply) {
    if (String.isBlank(topReply)) {
      return false;
    }
    if (SEE_BELOW_PATTERN.matcher(topReply).find()) {
      return false;
    }
    return hasAttendeeSignals(topReply);
  }

  private static Boolean hasAttendeeSignals(String bodyText) {
    if (String.isBlank(bodyText)) {
      return false;
    }
    String lower = bodyText.toLowerCase();
    if (
      lower.contains('attendee name:') ||
      lower.contains('attendee email:') ||
      lower.contains('event:') ||
      lower.contains('registration')
    ) {
      return true;
    }
    return EMAIL_PATTERN.matcher(bodyText).find();
  }

  private static String decodeHtmlEntities(String bodyText) {
    if (String.isBlank(bodyText)) {
      return '';
    }
    return bodyText
      .replace('&amp;', '&')
      .replace('&lt;', '<')
      .replace('&gt;', '>')
      .replace('&quot;', '"')
      .replace('&#39;', '\'')
      .replace('&#124;', '|')
      .replace('&nbsp;', ' ');
  }

  private static EmailMessage findOutgoingByTokenAndSender(
    Id opportunityId,
    String fromAddr
  ) {
    String token = '[REG:' + String.valueOf(opportunityId) + ']';
    List<EmailMessage> candidates = [
      SELECT Id, ToAddress
      FROM EmailMessage
      WHERE
        Incoming = FALSE
        AND RelatedToId = :opportunityId
        AND Subject LIKE :('%' + token + '%')
      ORDER BY CreatedDate DESC
      LIMIT 25
    ];

    for (EmailMessage candidate : candidates) {
      if (addressListContains(candidate.ToAddress, fromAddr)) {
        return candidate;
      }
    }
    return null;
  }

  private static EmailMessage findLegacyOutgoingBySender(String fromAddr) {
    Datetime cutoff = System.now().addDays(-LEGACY_LOOKBACK_DAYS);
    String subjectPrefix = SUBJECT_PATTERN + '%';
    List<EmailMessage> candidates = [
      SELECT Id, RelatedToId, ToAddress
      FROM EmailMessage
      WHERE
        Incoming = FALSE
        AND RelatedToId != NULL
        AND Subject LIKE :subjectPrefix
        AND CreatedDate >= :cutoff
      ORDER BY CreatedDate DESC
      LIMIT 50
    ];

    for (EmailMessage candidate : candidates) {
      if (addressListContains(candidate.ToAddress, fromAddr)) {
        return candidate;
      }
    }
    return null;
  }

  @TestVisible
  private static Id extractOpportunityIdFromSubject(String subject) {
    if (String.isBlank(subject)) {
      return null;
    }
    Matcher m = REG_TOKEN_PATTERN.matcher(subject);
    if (!m.find()) {
      return null;
    }
    String rawId = m.group(1);
    try {
      return (Id) rawId;
    } catch (Exception e) {
      return null;
    }
  }

  @TestVisible
  private static Boolean addressListContains(
    String addressList,
    String targetEmail
  ) {
    if (String.isBlank(addressList) || String.isBlank(targetEmail)) {
      return false;
    }
    String target = normalizeEmail(targetEmail);
    if (String.isBlank(target)) {
      return false;
    }
    String targetDomain = extractEmailDomain(target);
    String normalizedList = addressList.replace(',', ';');
    for (String token : normalizedList.split(';')) {
      String candidate = normalizeEmail(token);
      if (String.isBlank(candidate)) {
        continue;
      }
      // Allow strict email match, or same domain as the original recipient.
      if (
        target == candidate ||
        (!String.isBlank(targetDomain) &&
        targetDomain == extractEmailDomain(candidate))
      ) {
        return true;
      }
    }
    return false;
  }

  @TestVisible
  private static String extractEmailDomain(String rawEmail) {
    String value = normalizeEmail(rawEmail);
    if (String.isBlank(value)) {
      return null;
    }
    Integer at = value.lastIndexOf('@');
    if (at <= 0 || at >= value.length() - 1) {
      return null;
    }
    return value.substring(at + 1);
  }

  private static String normalizeEmail(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String value = raw.trim().toLowerCase();

    Integer lt = value.indexOf('<');
    Integer gt = value.indexOf('>');
    if (lt >= 0 && gt > lt) {
      value = value.substring(lt + 1, gt).trim();
    }

    if (value.startsWith('"') && value.endsWith('"') && value.length() > 1) {
      value = value.substring(1, value.length() - 1);
    }
    return String.isBlank(value) ? null : value;
  }
}
