import { LightningElement, api } from 'lwc';

export default class ErKpiCards extends LightningElement {
    @api summary;

    get cards() {
        const s = this.summary || {};
        const def = [
            ['total', 'Monitored cases', s.total, ''],
            ['crit', 'Critical', s.critical, s.critical > 0 ? 'er-kpi-danger' : ''],
            ['high', 'High risk', s.high, s.high > 0 ? 'er-kpi-warn' : ''],
            ['sla', 'Approaching SLA (80%+)', s.approachingSla, s.approachingSla > 0 ? 'er-kpi-warn' : ''],
            ['appr', 'Awaiting approval', s.awaitingApproval, ''],
            ['fail', 'Failed AI assessments', s.failedAi, s.failedAi > 0 ? 'er-kpi-warn' : ''],
            ['avg', 'Average risk score', s.averageScore, '']
        ];
        return def.map(([key, label, value, tone]) => ({
            key,
            label,
            value: value === undefined || value === null ? '-' : value,
            aria: `${label}: ${value === undefined || value === null ? 'not available' : value}`,
            className: `slds-box slds-box_x-small er-kpi ${tone}`
        }));
    }
}
