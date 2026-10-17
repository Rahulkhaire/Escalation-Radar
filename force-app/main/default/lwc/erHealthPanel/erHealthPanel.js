import { LightningElement, api } from 'lwc';

export default class ErHealthPanel extends LightningElement {
    @api health;
    @api canExecute = false;

    get aiText() {
        if (!this.health) {
            return '';
        }
        return this.health.aiEnabled ? `${this.health.aiProvider} (enabled)` : 'disabled - deterministic scoring only';
    }
    get slackText() {
        return this.health && this.health.slackEnabled ? 'enabled' : 'disabled';
    }
    handleRetry() {
        this.dispatchEvent(new CustomEvent('retryfailed'));
    }
}
