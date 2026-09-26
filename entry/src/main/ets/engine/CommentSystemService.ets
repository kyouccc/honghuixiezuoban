/**
 * CommentSystemService.ets — 评论/标注系统（P1 增强）
 *
 * 提供笔记内添加评论、标注、回复、解决/关闭功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'CommentSystemService';

export interface Comment {
  id: string;
  author: string;
  content: string;
  createdAt: number;
  resolved: boolean;
  replyTo: string | null;
}

export interface CommentThread {
  id: string;
  noteId: string;
  pageIndex: number;
  x: number;
  y: number;
  comments: Comment[];
}

export class CommentSystemService {
  private static instance: CommentSystemService;
  private threads: CommentThread[] = [];

  static getInstance(): CommentSystemService {
    if (!CommentSystemService.instance) {
      CommentSystemService.instance = new CommentSystemService();
    }
    return CommentSystemService.instance;
  }

  getThreads(): CommentThread[] {
    return this.threads;
  }

  addThread(noteId: string, pageIndex: number, x: number, y: number): CommentThread {
    const thread: CommentThread = {
      id: Date.now().toString(),
      noteId: noteId,
      pageIndex: pageIndex,
      x: x,
      y: y,
      comments: []
    };
    this.threads.push(thread);
    return thread;
  }

  addComment(threadId: string, author: string, content: string, replyTo: string | null): Comment | null {
    const thread = this.threads.find(t => t.id === threadId);
    if (!thread) return null;
    const comment: Comment = {
      id: Date.now().toString(),
      author: author,
      content: content,
      createdAt: Date.now(),
      resolved: false,
      replyTo: replyTo
    };
    thread.comments.push(comment);
    return comment;
  }

  resolveComment(commentId: string): boolean {
    for (const t of this.threads) {
      const c = t.comments.find(c => c.id === commentId);
      if (c) {
        c.resolved = true;
        return true;
      }
    }
    return false;
  }

  resolveThread(threadId: string): boolean {
    const thread = this.threads.find(t => t.id === threadId);
    if (!thread) return false;
    for (const c of thread.comments) {
      c.resolved = true;
    }
    return true;
  }

  removeThread(threadId: string): boolean {
    const idx = this.threads.findIndex(t => t.id === threadId);
    if (idx < 0) return false;
    this.threads.splice(idx, 1);
    return true;
  }
}
