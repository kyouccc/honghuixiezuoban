/**
 * PollTimerService.ets — 投票/计时器（P2 扩展）
 *
 * 提供白板协作中的投票功能和计时器功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'PollTimerService';

export interface PollOption {
  id: string;
  text: string;
  votes: number;
}

export interface Poll {
  id: string;
  question: string;
  options: PollOption[];
  active: boolean;
  createdBy: string;
  endTime: number;
}

export interface TimerSession {
  id: string;
  label: string;
  duration: number;
  remaining: number;
  running: boolean;
}

export class PollTimerService {
  private static instance: PollTimerService;
  private polls: Poll[] = [];
  private timers: TimerSession[] = [];
  private timerId: number = -1;

  static getInstance(): PollTimerService {
    if (!PollTimerService.instance) {
      PollTimerService.instance = new PollTimerService();
    }
    return PollTimerService.instance;
  }

  createPoll(question: string, options: string[], createdBy: string, durationSec: number): Poll {
    const pollOptions: PollOption[] = [];
    for (let i = 0; i < options.length; i++) {
      pollOptions.push({ id: `opt_${i}`, text: options[i], votes: 0 });
    }
    const poll: Poll = {
      id: Date.now().toString(),
      question: question,
      options: pollOptions,
      active: true,
      createdBy: createdBy,
      endTime: Date.now() + durationSec * 1000
    };
    this.polls.push(poll);
    return poll;
  }

  vote(pollId: string, optionId: string): boolean {
    const poll = this.polls.find(p => p.id === pollId);
    if (!poll || !poll.active) return false;
    const option = poll.options.find(o => o.id === optionId);
    if (!option) return false;
    option.votes++;
    return true;
  }

  closePoll(pollId: string): boolean {
    const poll = this.polls.find(p => p.id === pollId);
    if (!poll) return false;
    poll.active = false;
    return true;
  }

  getPolls(): Poll[] { return this.polls; }

  createTimer(label: string, durationSec: number): TimerSession {
    const timer: TimerSession = {
      id: Date.now().toString(),
      label: label,
      duration: durationSec,
      remaining: durationSec,
      running: false
    };
    this.timers.push(timer);
    return timer;
  }

  startTimer(timerId: string): boolean {
    const timer = this.timers.find(t => t.id === timerId);
    if (!timer || timer.running) return false;
    timer.running = true;
    this.timerId = setInterval(() => {
      this.tickTimers();
    }, 1000);
    return true;
  }

  stopTimer(timerId: string): boolean {
    const timer = this.timers.find(t => t.id === timerId);
    if (!timer) return false;
    timer.running = false;
    if (this.timers.every(t => !t.running)) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    return true;
  }

  getTimers(): TimerSession[] { return this.timers; }

  private tickTimers(): void {
    for (const t of this.timers) {
      if (t.running && t.remaining > 0) {
        t.remaining--;
      }
      if (t.running && t.remaining <= 0) {
        t.running = false;
      }
    }
  }
}
