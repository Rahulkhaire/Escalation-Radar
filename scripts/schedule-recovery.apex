// Schedules the recovery batch every 15 minutes (retries due AI analyses, repairs assessments in Error).
// Run once: sf apex run --file scripts/schedule-recovery.apex --target-org escalation-radar-dev
// Salesforce cron has no "every 15 minutes" in one expression, so four jobs are scheduled.
for (Integer m : new List<Integer>{ 0, 15, 30, 45 }) {
    System.schedule('ER Recovery :' + (m < 10 ? '0' : '') + m, '0 ' + m + ' * * * ?', new ER_RecoverySchedulable());
}
