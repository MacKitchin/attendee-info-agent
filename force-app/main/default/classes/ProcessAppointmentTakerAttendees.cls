/**
 * @description Invocable Apex to process Appointment Taker attendees from JSON and assign to available OpportunityLineItems.
 * @author Agentforce
 * @group Attendee Processing
 * @date 2026-02-10
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
    }

    /**
     * @description Result wrapper for invocable method
     */
    public class Result {
        @InvocableVariable
        public Boolean isSuccess;
        @InvocableVariable
        public String statusMessage;

        public Result(Boolean isSuccess, String statusMessage) {
            this.isSuccess = isSuccess;
            this.statusMessage = statusMessage;
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

    /**
     * @description Invocable entry point to process attendees for Appointment Taker OLIs on an Opportunity.
     * Accepts a list to support Flow bulkification; each request is processed independently.
     * @param requests List of Request containing jsonString (array of attendees) and opportunityId
     * @return List of Result containing isSuccess and statusMessage
     */
    @InvocableMethod(label='Process Appointment Taker Attendees' description='Maps attendees from JSON to empty Appointment Taker line items on the given Opportunity.')
    public static List<Result> process(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            results.add(new Result(true, buildStatus(STATUS_PART.NO_ATTENDEES_PROVIDED, 'No requests to process.')));
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
            return new Result(false, buildStatus(STATUS_PART.ERROR, 'opportunityId is required.'));
        }
        if (String.isBlank(req.jsonString)) {
            // Treat missing attendees as a no-op success
            return new Result(true, buildStatus(STATUS_PART.NO_ATTENDEES_PROVIDED, 'Empty jsonString.'));
        }

        // Parse and validate JSON
        List<Attendee> attendees;
        try {
            attendees = parseAttendees(req.jsonString);
        } catch (ProcessException pe) {
            return new Result(false, buildStatus(STATUS_PART.INVALID_JSON, pe.getMessage()));
        } catch (Exception e) {
            return new Result(false, buildStatus(STATUS_PART.INVALID_JSON, 'Unexpected error parsing JSON: ' + e.getMessage()));
        }

        if (attendees.isEmpty()) {
            return new Result(true, buildStatus(STATUS_PART.NO_ATTENDEES_PROVIDED, 'No attendees found in jsonString.'));
        }

        // Load available OLIs (WITH USER_MODE to enforce user security)
        List<OpportunityLineItem> available = [
            SELECT Id, OpportunityId, Product2.Name, CreatedDate,
                   Attendee_First_Name__c, Attendee_Name__c, Attendee_Email__c
            FROM OpportunityLineItem
            WHERE OpportunityId = :req.opportunityId
              AND Product2.Name = 'Appointment Taker'
              AND (Attendee_Name__c = null OR Attendee_Email__c = null)
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        if (available.isEmpty()) {
            return new Result(true, buildStatus(STATUS_PART.NO_MATCHING_LINE_ITEMS, 'No open Appointment Taker line items found.'));
        }

        // Assign attendees to earliest-created open slots.
        // Build clean SObject instances with only Id + target fields to avoid
        // USER_MODE FLS errors on read-only relationship fields from the query.
        Integer assignable = Math.min(attendees.size(), available.size());
        List<OpportunityLineItem> toUpdate = new List<OpportunityLineItem>();
        for (Integer i = 0; i < assignable; i++) {
            Attendee a = attendees[i];
            OpportunityLineItem upd = new OpportunityLineItem(Id = available[i].Id);
            upd.Attendee_First_Name__c = a.firstName;
            upd.Attendee_Name__c = a.firstName + ' ' + a.lastName;
            upd.Attendee_Email__c = a.email;
            toUpdate.add(upd);
        }

        if (toUpdate.isEmpty()) {
            // Should not happen due to earlier checks, but guard anyway
            return new Result(true, buildStatus(STATUS_PART.NO_MATCHING_LINE_ITEMS, 'No slots updated.'));
        }

        // Bulk update with USER_MODE, allOrNone=false for resilience
        Database.SaveResult[] srList = Database.update(toUpdate, false, AccessLevel.USER_MODE);

        // Compute result counts and message
        Integer successCount = 0;
        List<String> errs = new List<String>();
        for (Integer i = 0; i < srList.size(); i++) {
            if (srList[i].isSuccess()) {
                successCount++;
            } else {
                for (Database.Error e : srList[i].getErrors()) {
                    errs.add('OLI ' + toUpdate[i].Id + ': ' + e.getStatusCode() + ' - ' + e.getMessage());
                }
            }
        }

        Integer unassignedFromCapacity = available.size() - successCount;
        Integer unassignedFromDemand = Math.max(0, attendees.size() - successCount);
        // prefer attendee-centric unassigned count for clarity
        Integer notAssigned = unassignedFromDemand;

        String detail = 'Attendees provided=' + attendees.size() +
                        ', assigned=' + successCount +
                        ', notAssigned=' + notAssigned +
                        ', openSlots=' + available.size();

        if (!errs.isEmpty()) {
            detail += '. Errors: ' + String.join(errs, ' | ');
        }

        if (successCount == attendees.size()) {
            return new Result(true, buildStatus(STATUS_PART.SUCCESS_ASSIGNED, detail));
        } else if (successCount > 0) {
            return new Result(true, buildStatus(STATUS_PART.PARTIAL_ASSIGNED, detail));
        } else {
            return new Result(false, buildStatus(STATUS_PART.ERROR, detail));
        }
    }

    /**
     * @description Helper to build a consistent status message
     */
    private static String buildStatus(STATUS_PART part, String message) {
        return String.valueOf(part) + ': ' + (message == null ? '' : message);
    }

    /**
     * @description Lightweight attendee DTO
     */
    private class Attendee {
        String firstName;
        String lastName;
        String email;

        Attendee(String firstName, String lastName, String email) {
            this.firstName = firstName;
            this.lastName = lastName;
            this.email = email;
        }
    }

    /**
     * @description Custom exception for processing errors
     */
    private class ProcessException extends Exception {}

    /**
     * @description Parse attendees from a JSON array of objects with keys: first_name, last_name, email
     * Uses JSON.deserializeUntyped to validate structure explicitly.
     */
    private static List<Attendee> parseAttendees(String jsonString) {
        Object root = JSON.deserializeUntyped(jsonString);
        if (!(root instanceof List<Object>)) {
            throw new ProcessException('JSON must be an array.');
        }
        List<Object> rawList = (List<Object>)root;
        List<Attendee> out = new List<Attendee>();
        for (Object row : rawList) {
            if (!(row instanceof Map<String, Object>)) {
                // Skip non-object entries rather than failing all
                continue;
            }
            Map<String, Object> m = (Map<String, Object>)row;
            String fn = (m.containsKey('first_name') && m.get('first_name') != null) ? String.valueOf(m.get('first_name')).trim() : null;
            String ln = (m.containsKey('last_name') && m.get('last_name') != null) ? String.valueOf(m.get('last_name')).trim() : null;
            String em = (m.containsKey('email') && m.get('email') != null) ? String.valueOf(m.get('email')).trim() : null;

            // Require at minimum email and first name; allow empty last name
            if (String.isBlank(fn) || String.isBlank(em)) {
                // Skip invalid attendee rows
                continue;
            }
            if (ln == null) {
                ln = '';
            }
            out.add(new Attendee(fn, ln, em));
        }
        return out;
    }
}
