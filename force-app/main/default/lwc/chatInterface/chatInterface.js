import { LightningElement, track } from 'lwc';
import getChatHistory from '@salesforce/apex/ChatController.getChatHistory';
import processMessage from '@salesforce/apex/ChatController.processMessage';
import generateSessionId from '@salesforce/apex/ChatController.generateSessionId';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ChatInterface extends LightningElement {
    @track messages = [];
    @track currentMessage = '';
    @track isLoading = false;
    @track sessionId = '';

    connectedCallback() {
        this.initializeChat();
    }

    async initializeChat() {
        try {
            this.sessionId = await generateSessionId();
            await this.loadChatHistory();
        } catch (error) {
            this.showToast('Error', 'Failed to initialize chat', 'error');
        }
    }

    async loadChatHistory() {
        try {
            const history = await getChatHistory({ sessionId: this.sessionId });
            // Clone to avoid mutating frozen objects and add isUser flag
            this.messages = (history || []).map((m) => ({
                ...m,
                isUser: m.messageType === 'User'
            }));
            this.scrollToBottom();
        } catch (error) {
            this.showToast('Error', 'Failed to load chat history', 'error');
        }
    }

    handleMessageChange(event) {
        this.currentMessage = event.target.value;
    }

    async handleSendMessage() {
        if (!this.currentMessage.trim()) return;

        const userMessage = this.currentMessage;
        this.currentMessage = '';
        this.isLoading = true;

        // Create a new array instead of mutating existing
        const newUserMsg = {
            id: 'temp-' + Date.now(),
            message: userMessage,
            response: '',
            messageType: 'User',
            createdDate: new Date(),
            sessionId: this.sessionId,
            isUser: true
        };
        this.messages = [...this.messages, newUserMsg];

        this.scrollToBottom();

        try {
            // Process message and get AI response
            const aiResponse = await processMessage({ 
                message: userMessage, 
                sessionId: this.sessionId 
            });

            const newAiMsg = {
                id: aiResponse.id,
                message: aiResponse.message,
                response: aiResponse.response,
                messageType: 'AI',
                createdDate: aiResponse.createdDate,
                sessionId: aiResponse.sessionId,
                isUser: false
            };

            // Append without mutating
            this.messages = [...this.messages, newAiMsg];

            this.scrollToBottom();
        } catch (error) {
            this.showToast('Error', 'Failed to process message', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleKeyPress(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSendMessage();
        }
    }

    scrollToBottom() {
        setTimeout(() => {
            const chatMessages = this.template.querySelector('.chat-messages');
            if (chatMessages) {
                chatMessages.scrollTop = chatMessages.scrollHeight;
            }
        }, 100);
    }

    showToast(title, message, variant) {
        const evt = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(evt);
    }

    get hasMessages() {
        return this.messages.length > 0;
    }

    get isSendDisabled() {
        return !this.currentMessage.trim() || this.isLoading;
    }
}