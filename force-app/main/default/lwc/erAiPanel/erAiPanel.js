import { LightningElement, api } from 'lwc';

export default class ErAiPanel extends LightningElement {
    @api detail;

    get hasAi() {
        return !!(this.detail && this.detail.aiSummary);
    }
    get upliftText() {
        return this.detail && this.detail.aiUplift ? `+${this.detail.aiUplift} pts` : 'none';
    }
    get confidenceText() {
        return this.detail && this.detail.aiConfidence !== null && this.detail.aiConfidence !== undefined ? this.detail.aiConfidence : 'n/a';
    }
    get emptyText() {
        const d = this.detail || {};
        if (d.row && d.row.assessmentStatus === 'AI_Failed') {
            return `AI analysis failed after ${d.retryCount} attempt(s) (${d.lastError || 'no detail'}). The deterministic score is still valid.`;
        }
        if (d.row && d.row.assessmentStatus === 'AI_Pending') {
            return 'AI analysis is queued or waiting for a retry.';
        }
        return 'No AI analysis for this case (below the AI score threshold, or AI is disabled).';
    }
}
