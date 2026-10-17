/**
 * Deterministic, side-effect-free risk scoring. Maximum score is the sum of the configured
 * weights (35+20+15+15+15 = 100 with the example configuration). Every factor reports its
 * own contribution so the final score is fully explainable. The LLM never changes this score.
 */
public with sharing class ER_RiskScoringEngine {
    public class Input {
        public String priority;
        public Boolean isEscalated = false;
        public Boolean isClosed = false;
        public Datetime createdDate;
        public Integer reopenCount;
        public String accountTier;
        public Datetime lastPublicUpdate;
        public Datetime now;
        public Decimal slaConsumptionPct;
        public String slaSource;
    }

    public class Factor {
        public String key;
        public String label;
        public String detail;
        public String source = 'DETERMINISTIC';
        public Decimal points;
        public Decimal maxPoints;
    }

    public class Result {
        public Decimal score;
        public String category;
        public String ruleVersion;
        public List<Factor> factors = new List<Factor>();
        public String explanation;
    }

    public static Result score(Input input, ER_Config.RiskConfig cfg) {
        Result res = new Result();
        res.ruleVersion = cfg.version;
        Datetime nowTs = input.now == null ? Datetime.now() : input.now;

        // 1. SLA consumption
        Factor sla = factor('SLA', 'SLA consumption', cfg.wSla);
        if (input.slaConsumptionPct == null) {
            sla.points = 0;
            sla.detail = 'No SLA deadline or SLA policy is available, so SLA consumption was not scored.';
        } else {
            Decimal frac;
            if (cfg.slaRampStartPct >= 100) {
                frac = input.slaConsumptionPct >= 100 ? 1 : 0;
            } else {
                frac = clamp((input.slaConsumptionPct - cfg.slaRampStartPct) / (100 - cfg.slaRampStartPct));
            }
            sla.points = cfg.wSla * frac;
            sla.detail = 'SLA is ' + input.slaConsumptionPct.setScale(1) + '% consumed (' + input.slaSource + ').';
        }
        res.factors.add(sla);

        // 2. Priority (an escalated Case counts as maximum severity)
        Factor pri = factor('PRIORITY', 'Case priority and severity', cfg.wPriority);
        Decimal pFrac = input.priority == null ? 0.0 : nzFrac(cfg.priorityFractions.get(input.priority));
        if (input.isEscalated == true) {
            pFrac = 1;
        }
        pri.points = cfg.wPriority * clamp(pFrac);
        pri.detail = (input.priority == null ? 'Priority is not set.' : 'Priority is ' + input.priority + '.') +
            (input.isEscalated == true ? ' The Case is flagged as escalated.' : '');
        res.factors.add(pri);

        // 3. Reopen history
        Factor reo = factor('REOPEN', 'Reopen history', cfg.wReopen);
        Integer reopens = input.reopenCount == null ? 0 : input.reopenCount;
        Decimal rFrac = cfg.reopenCap > 0 ? Decimal.valueOf(reopens) / cfg.reopenCap : (reopens > 0 ? 1.0 : 0.0);
        reo.points = cfg.wReopen * clamp(rFrac);
        reo.detail = reopens == 0 ? 'The Case has not been reopened.' : 'The Case has been reopened ' + reopens + (reopens == 1 ? ' time.' : ' times.');
        res.factors.add(reo);

        // 4. Account tier
        Factor tier = factor('ACCOUNT_TIER', 'Account tier', cfg.wTier);
        Decimal tFrac = input.accountTier == null ? 0.0 : nzFrac(cfg.tierFractions.get(input.accountTier));
        tier.points = cfg.wTier * clamp(tFrac);
        tier.detail = input.accountTier == null ? 'Account tier is not set.' : 'The customer belongs to the ' + input.accountTier + ' account tier.';
        res.factors.add(tier);

        // 5. Case age and communication freshness
        Factor age = factor('AGE_COMMS', 'Case age and communication', cfg.wAgeComms);
        Decimal ageHours = input.createdDate == null ? 0.0 : hoursBetween(input.createdDate, nowTs);
        Datetime ref = input.lastPublicUpdate == null ? input.createdDate : input.lastPublicUpdate;
        Decimal staleHours = ref == null ? 0.0 : hoursBetween(ref, nowTs);
        Decimal ageFrac = cfg.ageCapHours > 0 ? clamp(ageHours / cfg.ageCapHours) : 0.0;
        Decimal staleFrac = cfg.staleUpdateHours > 0 ? clamp(staleHours / cfg.staleUpdateHours) : 0.0;
        age.points = cfg.wAgeComms * (ageFrac * 0.5 + staleFrac * 0.5);
        age.detail = 'The Case has been open ' + ageHours.setScale(0, RoundingMode.HALF_UP) + ' h; the customer has not received an update for ' +
            staleHours.setScale(0, RoundingMode.HALF_UP) + ' h.';
        res.factors.add(age);

        Decimal total = 0;
        List<String> reasons = new List<String>();
        for (Factor f : res.factors) {
            f.points = f.points.setScale(1, RoundingMode.HALF_UP);
            total += f.points;
            if (f.points > 0) {
                reasons.add(f.detail + ' (+' + f.points + ' of ' + f.maxPoints + ' pts)');
            }
        }
        res.score = clampScore(total, cfg);
        res.category = categorize(res.score, cfg);
        res.explanation = (reasons.isEmpty() ? 'No elevated risk factors were found. ' : String.join(reasons, ' ') + ' ') +
            'Score ' + res.score + '/100, rules v' + cfg.version + '.';
        return res;
    }

    public static String categorize(Decimal score, ER_Config.RiskConfig cfg) {
        if (score >= cfg.tCritical) {
            return ER_Constants.CAT_CRITICAL;
        }
        if (score >= cfg.tHigh) {
            return ER_Constants.CAT_HIGH;
        }
        if (score >= cfg.tMedium) {
            return ER_Constants.CAT_MEDIUM;
        }
        return ER_Constants.CAT_LOW;
    }

    private static Factor factor(String key, String label, Decimal max) {
        Factor f = new Factor();
        f.key = key;
        f.label = label;
        f.maxPoints = max;
        return f;
    }

    private static Decimal hoursBetween(Datetime a, Datetime b) {
        if (b <= a) {
            return 0.0;
        }
        return Decimal.valueOf(b.getTime() - a.getTime()) / 3600000;
    }

    private static Decimal clamp(Decimal v) {
        return v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
    }

    private static Decimal nzFrac(Decimal v) {
        return v == null ? 0.0 : v;
    }

    private static Decimal clampScore(Decimal v, ER_Config.RiskConfig cfg) {
        Decimal max = cfg.weightTotal() > 100 ? Decimal.valueOf(100) : cfg.weightTotal();
        Decimal r = v < 0 ? 0.0 : (v > max ? max : v);
        return r.setScale(1, RoundingMode.HALF_UP);
    }
}
