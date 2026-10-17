/**
 * Computes SLA consumption from either a supplied deadline (Case.ER_SLA_Deadline__c) or
 * a documented policy-hours fallback per priority. Never guesses: returns a null percentage
 * when neither source is available.
 */
public with sharing class ER_SlaCalculator {
    public class SlaResult {
        public Decimal consumptionPct;
        public Datetime effectiveDeadline;
        public String source = 'NONE';
    }

    public static SlaResult compute(
        Datetime createdDate,
        Datetime suppliedDeadline,
        String priority,
        Datetime now,
        ER_Config.RiskConfig cfg,
        Id businessHoursId
    ) {
        SlaResult r = new SlaResult();
        if (createdDate == null || now == null) {
            return r;
        }
        if (suppliedDeadline != null) {
            Long total = suppliedDeadline.getTime() - createdDate.getTime();
            Long elapsed = Math.max(0L, now.getTime() - createdDate.getTime());
            r.source = 'SUPPLIED_DEADLINE';
            r.effectiveDeadline = suppliedDeadline;
            if (total <= 0) {
                r.consumptionPct = 100;
            } else {
                r.consumptionPct = (Decimal.valueOf(elapsed) * 100 / Decimal.valueOf(total)).setScale(1, RoundingMode.HALF_UP);
            }
            return r;
        }
        Decimal hours = policyHours(priority, cfg);
        if (hours == null || hours <= 0) {
            return r;
        }
        Long totalMs = (hours * 3600000).longValue();
        if (cfg.slaUseBusinessHours && businessHoursId != null) {
            Long elapsedBh = now > createdDate ? BusinessHours.diff(businessHoursId, createdDate, now) : 0L;
            r.consumptionPct = (Decimal.valueOf(elapsedBh) * 100 / Decimal.valueOf(totalMs)).setScale(1, RoundingMode.HALF_UP);
            r.effectiveDeadline = BusinessHours.add(businessHoursId, createdDate, totalMs);
            r.source = 'POLICY_BUSINESS_HOURS';
        } else {
            Long elapsed = Math.max(0L, now.getTime() - createdDate.getTime());
            r.consumptionPct = (Decimal.valueOf(elapsed) * 100 / Decimal.valueOf(totalMs)).setScale(1, RoundingMode.HALF_UP);
            r.effectiveDeadline = Datetime.newInstance(createdDate.getTime() + totalMs);
            r.source = 'POLICY_CALENDAR_HOURS';
        }
        return r;
    }

    private static Decimal policyHours(String priority, ER_Config.RiskConfig cfg) {
        if (priority == 'High') {
            return cfg.slaHoursHigh;
        }
        if (priority == 'Medium') {
            return cfg.slaHoursMedium;
        }
        if (priority == 'Low') {
            return cfg.slaHoursLow;
        }
        return null;
    }
}
