/**
 * Shared constants. Single source of truth for category, status and action identifiers
 * so Apex, tests and LWC use exactly the same strings.
 */
public with sharing class ER_Constants {
    public static final String CAT_LOW = 'LOW';
    public static final String CAT_MEDIUM = 'MEDIUM';
    public static final String CAT_HIGH = 'HIGH';
    public static final String CAT_CRITICAL = 'CRITICAL';

    public static final String AS_SCORED = 'Scored';
    public static final String AS_AI_PENDING = 'AI_Pending';
    public static final String AS_ENRICHED = 'Enriched';
    public static final String AS_AI_FAILED = 'AI_Failed';
    public static final String AS_ERROR = 'Error';
    public static final String AS_INACTIVE = 'Inactive';

    public static final String ACT_DRAFT = 'DRAFT_CUSTOMER_UPDATE';
    public static final String ACT_REASSIGN = 'REASSIGN_CASE';
    public static final String ACT_REVIEW = 'REQUEST_MANAGER_REVIEW';
    public static final String ACT_ESCALATE = 'ESCALATE_CASE';
    public static final String ACT_SLACK = 'SEND_SLACK_ALERT';
    public static final String ACT_NOTE = 'ADD_INTERNAL_NOTE';

    /** The only action identifiers the system will ever accept, from any source (rules, AI, UI). */
    public static final Set<String> ALLOWED_ACTIONS = new Set<String>{
        ACT_DRAFT, ACT_REASSIGN, ACT_REVIEW, ACT_ESCALATE, ACT_SLACK, ACT_NOTE
    };
    /** Always require human approval, regardless of configuration. */
    public static final Set<String> ALWAYS_APPROVAL = new Set<String>{ ACT_REASSIGN, ACT_SLACK };

    public static final String APPR_NOT_REQUIRED = 'Not_Required';
    public static final String APPR_PENDING = 'Pending';
    public static final String APPR_APPROVED = 'Approved';
    public static final String APPR_REJECTED = 'Rejected';

    public static final String EX_NOT_STARTED = 'Not_Started';
    public static final String EX_EXECUTING = 'Executing';
    public static final String EX_SUCCEEDED = 'Succeeded';
    public static final String EX_FAILED = 'Failed';
    public static final String EX_SKIPPED = 'Skipped';

    public static final String PERM_APPROVE = 'ER_Approve_Actions';
    public static final String PERM_EXECUTE = 'ER_Execute_Actions';

    public static final String OUTCOME_SUCCESS = 'SUCCESS';
    public static final String OUTCOME_FAILURE = 'FAILURE';
    public static final String OUTCOME_INFO = 'INFO';

    public static Integer categoryRank(String category) {
        if (category == CAT_CRITICAL) {
            return 3;
        }
        if (category == CAT_HIGH) {
            return 2;
        }
        if (category == CAT_MEDIUM) {
            return 1;
        }
        return 0;
    }

    public static String newCorrelationId() {
        return 'ER-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 20);
    }
}
