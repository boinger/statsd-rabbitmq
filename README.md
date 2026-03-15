statsd-rabbitmq
===============

Scrape some base info out of rabbitmq and shove it into statsd

Usage
-----

    Usage: ./rabbitmq.watcher.rb [options]
        -P, --prefix [STATSD_PREFIX]     metric prefix (default: Socket.gethostname)
        -i, --interval [SEC]             reporting interval (default: 10)
        -h, --host [HOST]                statsd host (default: 127.0.0.1)
        -p, --port [PORT]                statsd port (default: 8125)
        -u, --rmquser [RABBITMQ_USER]    rabbitmq user (default: guest)
        -s, --rmqpass [RABBITMQ_PASS]    rabbitmq pass (default: guest)
        -r, --rmqhost [RABBITMQ_HOST]    rabbitmq server (default: 127.0.0.1)
        -b, --rmqport [RABBITMQ_PORT]    rabbitmq server port (default: 15672)
        -q, --[no-]queues                report queue metrics (default: no)

I like to put my ec2 instance id in the prefix, for example:

    rabbitmq.watcher.rb -P $(ec2metadata --instance-id)
