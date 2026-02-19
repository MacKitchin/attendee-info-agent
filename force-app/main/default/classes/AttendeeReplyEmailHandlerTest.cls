/**
 * @description Unit tests for AttendeeReplyEmailHandler
 */
@IsTest
private class AttendeeReplyEmailHandlerTest {

    @TestSetup
    static void setup() {
        Id stdPbId = Test.getStandardPricebookId();

        Account acc = new Account(Name = 'Test Handler Acme');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Test Handler Opp',
            StageName = 'Prospecting',
            CloseDate = System.today().addDays(10),
            AccountId = acc.Id,
            Pricebook2Id = stdPbId,
            RecordTypeId = '01230000000bVYmAAM',
            Sales_Territory__c = 'North'
        );
        insert opp;

        // Simulate the outgoing registration email that Flow A would create
        EmailMessage outgoing = new EmailMessage();
        outgoing.Subject = AttendeeReplyEmailHandler.SUBJECT_PATTERN;
        outgoing.TextBody = 'Please provide attendee details for your Appointment Taker registrations.';
        outgoing.FromAddress = 'production@connectmeetings.com';
        outgoing.ToAddress = 'signer@example.com';
        outgoing.Incoming = false;
        outgoing.Status = '3'; // Sent
        outgoing.MessageDate = System.now();
        outgoing.RelatedToId = opp.Id;
        insert outgoing;
    }

    private static Opportunity getTestOpportunity() {
        return [SELECT Id FROM Opportunity WHERE Name = 'Test Handler Opp' LIMIT 1];
    }

    /**
     * @description A reply from the original signer should create an incoming
     * EmailMessage linked to the same Opportunity as the outgoing email.
     */
    @IsTest
    static void testMatchingReply_createsIncomingEmailMessage() {
        Opportunity opp = getTestOpportunity();
        EmailMessage outgoing = [SELECT Id FROM EmailMessage WHERE Incoming = false LIMIT 1];

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
        email.fromAddress = 'signer@example.com';
        email.fromName = 'Test Signer';
        email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
        email.plainTextBody = 'Here are the attendees:\n1. Jane Doe - jane@example.com\n2. John Smith - john@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.fromAddress = 'signer@example.com';

        AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Handler should succeed');

        // Verify incoming EmailMessage was created and linked correctly
        List<EmailMessage> incoming = [
            SELECT Id, Subject, FromAddress, RelatedToId, Incoming, ReplyToEmailMessageId
            FROM EmailMessage
            WHERE Incoming = true
        ];
        System.assertEquals(1, incoming.size(), 'One incoming EmailMessage should be created');
        System.assertEquals(opp.Id, incoming[0].RelatedToId, 'Should be linked to the Opportunity');
        System.assertEquals(outgoing.Id, incoming[0].ReplyToEmailMessageId, 'Should reference the original outgoing email');
        System.assert(incoming[0].Subject.contains(AttendeeReplyEmailHandler.SUBJECT_PATTERN),
            'Subject should contain registration pattern');
    }

    /**
     * @description Emails with non-matching subjects should be silently accepted
     * with no EmailMessage created.
     */
    @IsTest
    static void testNonMatchingSubject_noAction() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Some unrelated email subject';
        email.fromAddress = 'random@example.com';
        email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
        email.plainTextBody = 'Hello';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.fromAddress = 'random@example.com';

        AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Should succeed but do nothing');

        List<EmailMessage> incoming = [SELECT Id FROM EmailMessage WHERE Incoming = true];
        System.assertEquals(0, incoming.size(), 'No incoming EmailMessage should be created');
    }

    /**
     * @description A reply from an unknown sender (no matching outgoing email)
     * should fail with a descriptive message.
     */
    @IsTest
    static void testNoMatchingOutgoingEmail_failure() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
        email.fromAddress = 'unknown@example.com';
        email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
        email.plainTextBody = 'Attendees: Jane Doe - jane@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.fromAddress = 'unknown@example.com';

        AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        System.assertEquals(false, result.success, 'Should fail when no matching outgoing email exists');
        System.assert(result.message.contains('No matching'), 'Should include descriptive error message');
    }

    /**
     * @description Null subject should be silently accepted (doesn't match pattern).
     */
    @IsTest
    static void testNullSubject_noAction() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = null;
        email.fromAddress = 'signer@example.com';
        email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
        email.plainTextBody = 'No subject email';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.fromAddress = 'signer@example.com';

        AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Should succeed silently for null subject');

        List<EmailMessage> incoming = [SELECT Id FROM EmailMessage WHERE Incoming = true];
        System.assertEquals(0, incoming.size(), 'No incoming EmailMessage should be created');
    }
}
