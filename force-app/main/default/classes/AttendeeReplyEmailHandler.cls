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

            String fromAddr = email.fromAddress;

            // Strip quoted reply content from the plain text body.
            // Outlook/Exchange appends the original message after a line of underscores.
            // We keep only the top portion (the actual reply) to avoid passing
            // oversized payloads to the Einstein prompt template.
            String plainBody = email.plainTextBody != null ? email.plainTextBody : '';
            Integer separatorIdx = plainBody.indexOf('________________________________');
            if (separatorIdx > 0) {
                plainBody = plainBody.substring(0, separatorIdx).trim();
            }

            // Decode HTML entities that Outlook injects into the plain text body.
            // These cause UndefinedResolutionError in the Einstein prompt template engine.
            plainBody = plainBody
                .replace('&amp;',  '&')
                .replace('&lt;',   '<')
                .replace('&gt;',   '>')
                .replace('&quot;', '"')
                .replace('&#39;',  '\'')
                .replace('&#124;', '|')
                .replace('&nbsp;', ' ');

            // Find the most recent outgoing registration email sent TO this sender
            // to determine the related Opportunity
            List<EmailMessage> originals = [
                SELECT Id, RelatedToId
                FROM EmailMessage
                WHERE Incoming = false
                  AND Subject = :SUBJECT_PATTERN
                  AND ToAddress LIKE :('%' + fromAddr + '%')
                  AND RelatedToId != null
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            if (originals.isEmpty()) {
                result.success = false;
                result.message = 'No matching outgoing registration email found for: ' + fromAddr;
                return result;
            }

            Id opportunityId = originals[0].RelatedToId;

            // Build and insert the incoming EmailMessage linked to the Opportunity.
            // This insert triggers Flow B (Event Registration - Process Attendee Reply).
            EmailMessage em = new EmailMessage();
            em.Subject = subject;
            em.TextBody = plainBody;  // stripped reply content only
            em.HtmlBody = null;       // omit HTML; prompt template uses TextBody only
            em.FromAddress = fromAddr;
            em.FromName = email.fromName;
            em.ToAddress = email.toAddresses != null
                ? String.join(email.toAddresses, '; ')
                : '';
            em.Incoming = true;
            em.Status = '0'; // New
            em.MessageDate = System.now();
            em.RelatedToId = opportunityId;
            em.ReplyToEmailMessageId = originals[0].Id;

            insert em;

            result.success = true;
        } catch (Exception e) {
            result.success = false;
            result.message = 'Error processing attendee reply: ' + e.getMessage();
        }

        return result;
    }
}
