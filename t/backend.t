use Mojo::Base -strict;

use Test::More;
use Minion::Backend;

# Abstract methods
eval { Minion::Backend->broadcast };
like $@, qr/Method "broadcast" not implemented by subclass/, 'right error';
eval { Minion::Backend->dequeue };
like $@, qr/Method "dequeue" not implemented by subclass/, 'right error';
eval { Minion::Backend->enqueue };
like $@, qr/Method "enqueue" not implemented by subclass/, 'right error';
eval { Minion::Backend->fail_job };
like $@, qr/Method "fail_job" not implemented by subclass/, 'right error';
eval { Minion::Backend->finish_job };
like $@, qr/Method "finish_job" not implemented by subclass/, 'right error';
eval { Minion::Backend->history };
like $@, qr/Method "history" not implemented by subclass/, 'right error';
eval { Minion::Backend->list_jobs };
like $@, qr/Method "list_jobs" not implemented by subclass/, 'right error';
eval { Minion::Backend->list_locks };
like $@, qr/Method "list_locks" not implemented by subclass/, 'right error';
eval { Minion::Backend->list_workers };
like $@, qr/Method "list_workers" not implemented by subclass/, 'right error';
eval { Minion::Backend->lock };
like $@, qr/Method "lock" not implemented by subclass/, 'right error';
eval { Minion::Backend->note };
like $@, qr/Method "note" not implemented by subclass/, 'right error';
eval { Minion::Backend->receive };
like $@, qr/Method "receive" not implemented by subclass/, 'right error';
eval { Minion::Backend->register_worker };
like $@, qr/Method "register_worker" not implemented by subclass/,
  'right error';
eval { Minion::Backend->remove_job };
like $@, qr/Method "remove_job" not implemented by subclass/, 'right error';
eval { Minion::Backend->repair };
like $@, qr/Method "repair" not implemented by subclass/, 'right error';
eval { Minion::Backend->reset };
like $@, qr/Method "reset" not implemented by subclass/, 'right error';
eval { Minion::Backend->retry_job };
like $@, qr/Method "retry_job" not implemented by subclass/, 'right error';
eval { Minion::Backend->stats };
like $@, qr/Method "stats" not implemented by subclass/, 'right error';
eval { Minion::Backend->unlock };
like $@, qr/Method "unlock" not implemented by subclass/, 'right error';
eval { Minion::Backend->unregister_worker };
like $@, qr/Method "unregister_worker" not implemented by subclass/,
  'right error';

done_testing();
