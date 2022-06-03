# polr_redirector

This a high performance link redirect replacement for [Polr](https://github.com/cydrobolt/polr), which is only aim to replace the short link redirection part, which is also the most performance demending portion.

## Installation

TODO: List C libraries that required to install

```shell
git clone https://github.com/danny8376/polr_redirector.git
shards build
bin/polr_redirector
```

## Usage

Before start, edit the config.yml as you need. You may want to check [the doc of crystal-db](https://crystal-lang.org/reference/1.4/database/connection_pool.html#configuration) about how to configure db_conf option.

First, run this server with ways you like.
For example, with systemd like:

```
[Unit]
Description=High performance link redirect replacement for Polr
After=network.target

[Service]
User=http
WorkingDirectory=<path to cloned location>
Environment=KEMAL_ENV=production
ExecStart=<path to cloned location>/bin/polr_redirector
ExecReload=/usr/bin/kill -HUP $MAINPID
Restart=always

[Install]
WantedBy=default.target
```

Then, configure your web server to actually use it. (I personally use nginx, so I'll use it as example. For other web server, modify the configuration according to the same principle, which is mentioned in the comments of the following nginx config example.)

```
upstream polr_redirector {
    server 127.0.0.1:54321; # the same as bind in config
    keepalive 8; # adjust this as required, or remove to disable keepalive for backend connections.
}

# Upstream to abstract backend connection(s) for php
upstream php {
    server unix:/var/run/php-fpm.sock;
    server 127.0.0.1:9000;
}

# HTTP
server {
    listen       *:80;
    root         /var/www/polr/public;
    index        index.php index.html index.htm;
    server_name  example.com; # Or whatever you want to use

#   return 301 https://$server_name$request_uri; # Forces HTTPS, which enables privacy for login credentials.
                                                 # Recommended for public, internet-facing, websites.

    # => discard the original full site rewrite
    #location / {
    #    try_files $uri $uri/ /index.php$is_args$args;
    #    # rewrite ^/([a-zA-Z0-9]+)/?$ /index.php?$1;
    #}

    # => only rewrite required portion to pass it the polr
    location = / {
        try_files $uri $uri/ /index.php$is_args$args;
        # rewrite ^/([a-zA-Z0-9]+)/?$ /index.php?$1;
    }
    location ~ ^/(signup|logout|login|about-polr|lost_password|activate/|reset_password/|admin|setup|shorten|api/) {
        try_files $uri $uri/ /index.php$is_args$args;
        # rewrite ^/([a-zA-Z0-9]+)/?$ /index.php?$1;
    }
    location ~ ^/(css|directives|fonts|img|js)/ {
        try_files $uri $uri/ /index.php$is_args$args;
        # rewrite ^/([a-zA-Z0-9]+)/?$ /index.php?$1;
    }

    # => pass the remaining part to polr_redirector, which are basically all short links (and non-existing part)
    location / {
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $server_name;
        proxy_pass http://polr_redirector;
    }

    location ~ \.php$ {
            try_files $uri =404;
            include /etc/nginx/fastcgi_params;

            fastcgi_pass    php;
            fastcgi_index   index.php;
            fastcgi_param   SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param   HTTP_HOST       $server_name;
    }
}

# HTTPS
# omitted, as it's the same principle.

```

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/danny8376/polr_redirector/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [danny8376](https://github.com/danny8376) DannyAAM - creator, maintainer
