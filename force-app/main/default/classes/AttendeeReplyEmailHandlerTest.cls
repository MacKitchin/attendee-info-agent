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

  private static Opportunity createOpportunity(String name) {
    Account acc = [
      SELECT Id
      FROM Account
      WHERE Name = 'Test Handler Acme'
      LIMIT 1
    ];
    Opportunity opp = new Opportunity(
      Name = name,
      StageName = 'Prospecting',
      CloseDate = System.today().addDays(10),
      AccountId = acc.Id,
      Pricebook2Id = Test.getStandardPricebookId(),
      RecordTypeId = '01230000000bVYmAAM',
      Sales_Territory__c = 'North'
    );
    insert opp;
    return opp;
  }

  private static EmailMessage createOutgoing(
    Id oppId,
    String subject,
    String toAddress
  ) {
    EmailMessage outgoing = new EmailMessage();
    outgoing.Subject = subject;
    outgoing.TextBody = 'Please provide attendee details for your Appointment Taker registrations.';
    outgoing.FromAddress = 'production@connectmeetings.com';
    outgoing.ToAddress = toAddress;
    outgoing.Incoming = false;
    outgoing.Status = '3';
    outgoing.MessageDate = System.now();
    outgoing.RelatedToId = oppId;
    insert outgoing;
    return outgoing;
  }

  /**
   * @description A reply from the original signer should create an incoming
   * EmailMessage linked to the same Opportunity as the outgoing email.
   */
  @IsTest
  static void testMatchingReply_createsIncomingEmailMessage() {
    Opportunity opp = getTestOpportunity();
    EmailMessage outgoing = [
      SELECT Id
      FROM EmailMessage
      WHERE Incoming = FALSE
      LIMIT 1
    ];

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
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success, 'Handler should succeed');

    // Verify incoming EmailMessage was created and linked correctly
    List<EmailMessage> incoming = [
      SELECT
        Id,
        Subject,
        FromAddress,
        RelatedToId,
        Incoming,
        ReplyToEmailMessageId
      FROM EmailMessage
      WHERE Incoming = TRUE
    ];
    System.assertEquals(
      1,
      incoming.size(),
      'One incoming EmailMessage should be created'
    );
    System.assertEquals(
      opp.Id,
      incoming[0].RelatedToId,
      'Should be linked to the Opportunity'
    );
    System.assertEquals(
      outgoing.Id,
      incoming[0].ReplyToEmailMessageId,
      'Should reference the original outgoing email'
    );
    System.assert(
      incoming[0].Subject.contains(AttendeeReplyEmailHandler.SUBJECT_PATTERN),
      'Subject should contain registration pattern'
    );
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
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success, 'Should succeed but do nothing');

    List<EmailMessage> incoming = [
      SELECT Id
      FROM EmailMessage
      WHERE Incoming = TRUE
    ];
    System.assertEquals(
      0,
      incoming.size(),
      'No incoming EmailMessage should be created'
    );
  }

  /**
   * @description A reply from an unknown sender (no matching outgoing email)
   * should fail with a descriptive message.
   */
  @IsTest
  static void testNoMatchingOutgoingEmail_failure() {
    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
    email.fromAddress = 'unknown@externaldomain.com';
    email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
    email.plainTextBody = 'Attendees: Jane Doe - jane@example.com';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'unknown@externaldomain.com';

    AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

    Test.startTest();
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(
      false,
      result.success,
      'Should fail when no matching outgoing email exists'
    );
    System.assert(
      result.message.contains('No matching'),
      'Should include descriptive error message'
    );
  }

  /**
   * @description When the email body contains the Outlook reply separator, only the
   * content BEFORE the separator should be stored as TextBody, and HtmlBody should be null.
   * This prevents oversized payloads being sent to the Einstein prompt template.
   */
  @IsTest
  static void testQuotedBodyStripping_onlyReplyContentStored() {
    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
    email.fromAddress = 'signer@example.com';
    email.fromName = 'Test Signer';
    email.toAddresses = new List<String>{ 'attendeeinfo@informa.com' };
    email.plainTextBody =
      'Jane Doe\njane@example.com\n\n' +
      '________________________________\n' +
      'From: Attendee Information <attendeeinfo@informa.com>\n' +
      'Subject: Action Required: Attendee Details for your Event Registrations\n\n' +
      'Hi Signer, please fill in your attendees below.';
    email.htmlBody = '<html><body>some big html</body></html>';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'signer@example.com';

    AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

    Test.startTest();
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success, 'Handler should succeed');

    EmailMessage created = [
      SELECT TextBody, HtmlBody
      FROM EmailMessage
      WHERE Incoming = TRUE
      LIMIT 1
    ];
    System.assert(
      !created.TextBody.contains('________________________________'),
      'TextBody should not contain the Outlook separator'
    );
    System.assert(
      !created.TextBody.contains('From: Attendee Information'),
      'Quoted original email should be stripped from TextBody'
    );
    System.assert(
      created.TextBody.contains('Jane Doe'),
      'Reply content should be preserved in TextBody'
    );
    System.assertEquals(
      null,
      created.HtmlBody,
      'HtmlBody should be null to keep payload small'
    );
  }

  /**
   * @description If the signer replies with "see below" and fills attendee details
   * inside the quoted/original content, that content should be retained for parsing.
   */
  @IsTest
  static void testSeeBelowReply_quotedBodyRetainedWhenTopHasNoAttendeeData() {
    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
    email.fromAddress = 'signer@example.com';
    email.fromName = 'Test Signer';
    email.toAddresses = new List<String>{ 'attendeeinfo@informa.com' };
    email.plainTextBody =
      'Please see below.\n\n' +
      '________________________________\n' +
      '-----Original Message-----\n' +
      'From: Attendee Information <attendeeinfo@informa.com>\n' +
      'Subject: Action Required: Attendee Details for your Event Registrations\n\n' +
      '1. Event: Spring Marketplace | Type: Association\n' +
      'Attendee Name: Nikki Gustafson\n' +
      'Attendee Email: nikki@visitstcloud.com\n';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'signer@example.com';

    AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

    Test.startTest();
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success, 'Handler should succeed');

    EmailMessage created = [
      SELECT TextBody
      FROM EmailMessage
      WHERE Incoming = TRUE
      LIMIT 1
    ];
    System.assert(
      created.TextBody.contains('Please see below.'),
      'Full body should be preserved so AI sees both reply intent and registration context'
    );
    System.assert(
      created.TextBody.contains('Attendee Name: Nikki Gustafson'),
      'Quoted attendee name should be retained'
    );
    System.assert(
      created.TextBody.contains('Attendee Email: nikki@visitstcloud.com'),
      'Quoted attendee email should be retained'
    );
  }

  /**
   * @description When the email body uses -----Original Message----- as the reply
   * separator (common in non-Outlook clients), only the top reply should be stored.
   */
  @IsTest
  static void testOriginalMessageSeparator_topReplyKept() {
    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
    email.fromAddress = 'signer@example.com';
    email.fromName = 'Test Signer';
    email.toAddresses = new List<String>{ 'attendeeinfo@informa.com' };
    email.plainTextBody =
      'Jen Henkel, DeVos Place Convention Center\n' +
      'jhenkel@grandrapidsvenues.com\n\n' +
      'Mary\n\n' +
      'Mary Manier, Vice President of Sales\n' +
      '616-233-3554\n\n' +
      '-----Original Message-----\n' +
      'From: Attendee Information <attendeeinfo@informa.com>\n' +
      'Subject: Action Required: Attendee Details for your Event Registrations\n\n' +
      'Hi Mary,\n\n' +
      '1. Event: MEGA | Registration Type: Non-Appointment Taker | Type: Association\n' +
      'Attendee Name:\nAttendee Email:\n';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'signer@example.com';

    AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

    Test.startTest();
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success, 'Handler should succeed');

    EmailMessage created = [
      SELECT TextBody
      FROM EmailMessage
      WHERE Incoming = TRUE
      LIMIT 1
    ];
    System.assert(
      !created.TextBody.contains('-----Original Message-----'),
      'Original message separator should be stripped'
    );
    System.assert(
      !created.TextBody.contains('Attendee Name:'),
      'Original template with empty fields should be stripped'
    );
    System.assert(
      created.TextBody.contains('jhenkel@grandrapidsvenues.com'),
      'Attendee email from top reply should be preserved'
    );
  }

  /**
   * @description HTML entities from Outlook (e.g. &amp; &lt; &#124;) should be decoded
   * in the stored TextBody so the Einstein prompt template can process it.
   */
  @IsTest
  static void testHtmlEntityDecoding_entitiesDecodedInTextBody() {
    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + AttendeeReplyEmailHandler.SUBJECT_PATTERN;
    email.fromAddress = 'signer@example.com';
    email.fromName = 'Test Signer';
    email.toAddresses = new List<String>{ 'attendeeinfo@informa.com' };
    email.plainTextBody =
      'Jane Doe\njane@example.com\n\n' +
      'AI &amp; Innovation Lead &#124; Connect\n' +
      'william.kitchin@informa.com&lt;mailto:william.kitchin@informa.com&gt;';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'signer@example.com';

    AttendeeReplyEmailHandler handler = new AttendeeReplyEmailHandler();

    Test.startTest();
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(true, result.success);
    EmailMessage created = [
      SELECT TextBody
      FROM EmailMessage
      WHERE Incoming = TRUE
      LIMIT 1
    ];
    System.assert(
      !created.TextBody.contains('&amp;'),
      'HTML entity &amp; should be decoded'
    );
    System.assert(
      !created.TextBody.contains('&#124;'),
      'HTML entity &#124; should be decoded'
    );
    System.assert(
      !created.TextBody.contains('&lt;'),
      'HTML entity &lt; should be decoded'
    );
    System.assert(
      created.TextBody.contains('AI & Innovation Lead | Connect'),
      'Decoded text should be present'
    );
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
    Messaging.InboundEmailResult result = handler.handleInboundEmail(
      email,
      envelope
    );
    Test.stopTest();

    System.assertEquals(
      true,
      result.success,
      'Should succeed silently for null subject'
    );

    List<EmailMessage> incoming = [
      SELECT Id
      FROM EmailMessage
      WHERE Incoming = TRUE
    ];
    System.assertEquals(
      0,
      incoming.size(),
      'No incoming EmailMessage should be created'
    );
  }

  /**
   * @description If multiple opportunities exist for the same signer, token-based
   * subject routing should link to the explicit opportunity token instead of the
   * most recent outgoing message.
   */
  @IsTest
  static void testTokenRouting_sameSenderMultipleOpportunities_routesByToken() {
    Opportunity olderOpp = createOpportunity('Token Opp Older');
    Opportunity newerOpp = createOpportunity('Token Opp Newer');

    String olderSubject =
      AttendeeReplyEmailHandler.SUBJECT_PATTERN +
      ' [REG:' +
      olderOpp.Id +
      ']';
    String newerSubject =
      AttendeeReplyEmailHandler.SUBJECT_PATTERN +
      ' [REG:' +
      newerOpp.Id +
      ']';

    EmailMessage olderOutgoing = createOutgoing(
      olderOpp.Id,
      olderSubject,
      'signer@example.com'
    );
    Test.setCreatedDate(olderOutgoing.Id, System.now().addMinutes(-10));
    EmailMessage newerOutgoing = createOutgoing(
      newerOpp.Id,
      newerSubject,
      'signer@example.com'
    );

    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + olderSubject;
    email.fromAddress = 'signer@example.com';
    email.fromName = 'Test Signer';
    email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
    email.plainTextBody = 'Attendees: Jane Doe - jane@example.com';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'signer@example.com';

    Test.startTest();
    Messaging.InboundEmailResult result = new AttendeeReplyEmailHandler()
      .handleInboundEmail(email, envelope);
    Test.stopTest();

    System.assertEquals(
      true,
      result.success,
      'Token-based routing should succeed'
    );

    EmailMessage created = [
      SELECT RelatedToId, ReplyToEmailMessageId
      FROM EmailMessage
      WHERE Incoming = TRUE
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    System.assertEquals(
      olderOpp.Id,
      created.RelatedToId,
      'Must route to opportunity referenced in token, not most recent outgoing'
    );
    System.assertEquals(
      olderOutgoing.Id,
      created.ReplyToEmailMessageId,
      'Reply link should point at the matching tokenized outgoing message'
    );
    System.assertNotEquals(
      newerOutgoing.Id,
      created.ReplyToEmailMessageId,
      'Should not attach to the newer outgoing message'
    );
  }

  /**
   * @description If a token is present and the sender shares the same domain as
   * the original recipient, allow routing to the tokenized opportunity thread.
   */
  @IsTest
  static void testTokenRouting_sameDomainSender_allowed() {
    Opportunity opp = createOpportunity('Token Same Domain Opp');
    String tokenSubject =
      AttendeeReplyEmailHandler.SUBJECT_PATTERN +
      ' [REG:' +
      opp.Id +
      ']';
    EmailMessage outgoing = createOutgoing(
      opp.Id,
      tokenSubject,
      'signer@example.com'
    );

    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + tokenSubject;
    email.fromAddress = 'teammate@example.com';
    email.fromName = 'Teammate Sender';
    email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
    email.plainTextBody = 'Attendees: Team Mate - teammate@example.com';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'teammate@example.com';

    Test.startTest();
    Messaging.InboundEmailResult result = new AttendeeReplyEmailHandler()
      .handleInboundEmail(email, envelope);
    Test.stopTest();

    System.assertEquals(
      true,
      result.success,
      'Token + same domain should be accepted'
    );

    EmailMessage created = [
      SELECT RelatedToId, ReplyToEmailMessageId
      FROM EmailMessage
      WHERE Incoming = TRUE
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    System.assertEquals(opp.Id, created.RelatedToId);
    System.assertEquals(outgoing.Id, created.ReplyToEmailMessageId);
  }

  /**
   * @description If a token is present but the sender does not match the original
   * recipient email or domain for that tokenized thread, reject the message
   * instead of misrouting.
   */
  @IsTest
  static void testTokenRouting_senderMismatch_rejected() {
    Opportunity opp = createOpportunity('Token Sender Mismatch Opp');
    String tokenSubject =
      AttendeeReplyEmailHandler.SUBJECT_PATTERN +
      ' [REG:' +
      opp.Id +
      ']';
    createOutgoing(opp.Id, tokenSubject, 'signer@example.com');

    Messaging.InboundEmail email = new Messaging.InboundEmail();
    email.subject = 'Re: ' + tokenSubject;
    email.fromAddress = 'different.person@anotherdomain.com';
    email.fromName = 'Different Sender';
    email.toAddresses = new List<String>{ 'production@connectmeetings.com' };
    email.plainTextBody = 'Attendees: Someone Else - someone@example.com';

    Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
    envelope.fromAddress = 'different.person@anotherdomain.com';

    Test.startTest();
    Messaging.InboundEmailResult result = new AttendeeReplyEmailHandler()
      .handleInboundEmail(email, envelope);
    Test.stopTest();

    System.assertEquals(
      false,
      result.success,
      'Token + sender mismatch should be rejected'
    );
    System.assert(
      result.message.contains('token') || result.message.contains('Token'),
      'Error message should indicate token validation failed'
    );

    List<EmailMessage> incoming = [
      SELECT Id
      FROM EmailMessage
      WHERE Incoming = TRUE
    ];
    System.assertEquals(
      0,
      incoming.size(),
      'No incoming EmailMessage should be created'
    );
  }
}
