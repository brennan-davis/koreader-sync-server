FROM ubuntu:jammy

RUN mkdir -p /bd_build/bin/

ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/buildconfig /bd_build/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/cleanup.sh /bd_build/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/prepare.sh /bd_build/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/system_services.sh /bd_build/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/utilities.sh /bd_build/

ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/bin/install_clean /bd_build/bin/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/bin/my_init /bd_build/bin/
ADD https://raw.githubusercontent.com/phusion/baseimage-docker/cc3f8f6fc8847a101efaf9008a892124b4ba14dc/image/bin/setuser /bd_build/bin/

RUN chmod 755 /bd_build/*.sh && chmod 755 /bd_build/bin/*

ENV DISABLE_CRON=1
ENV DISABLE_SSH=1
ENV DISABLE_SYSLOG=1

RUN /bd_build/prepare.sh && \
    /bd_build/system_services.sh && \
    /bd_build/utilities.sh && \
    /bd_build/cleanup.sh

ENV DEBIAN_FRONTEND="teletype" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8"

# install openresty
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        libreadline-dev libncurses5-dev libpcre3-dev libssl-dev \
        build-essential git openssl \
        luarocks unzip redis-server \
        zlib1g-dev curl supervisor \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ARG OPENRESTY_VER=1.21.4.1
ENV PATH /opt/openresty/nginx/sbin:$PATH

WORKDIR /app
RUN wget "http://openresty.org/download/openresty-${OPENRESTY_VER}.tar.gz" \
        && tar zxvf openresty-${OPENRESTY_VER}.tar.gz \
        && cd openresty-${OPENRESTY_VER} \
            && ./configure --prefix=/opt/openresty \
            && make && make install \
        && cd .. \
            && rm -rf openresty-${OPENRESTY_VER} openresty-${OPENRESTY_VER}.tar.gz /tmp/*

RUN mkdir -p /etc/nginx/ssl

# libssl.* are in /usr/lib/x86_64-linux-gnu on Travis Ubuntu precise
RUN luarocks install --verbose luasocket \
    && luarocks install luasec \
    && luarocks install redis-lua \
    && luarocks install busted \
    && rm -rf /tmp/*

# add app source code
COPY ./ koreader-sync-server

# patch gin for https support
RUN git clone https://github.com/ostinelli/gin \
    && cd gin && luarocks make \
    && rm -rf gin /tmp/*

# create daemons
RUN mkdir /etc/service/redis-server
RUN echo -n "#!/bin/sh\nexec redis-server /app/koreader-sync-server/config/redis.conf" > \
        /etc/service/redis-server/run
RUN chmod +x /etc/service/redis-server/run

# Create supervisord config
RUN mkdir -p /etc/supervisor/conf.d
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# run gin in production mode
ENV GIN_ENV=production \
    GIN_PORT=8080 \
    PORT=8080

# ensure nginx is not daemonizing
RUN echo "daemon off;" >> koreader-sync-server/config/nginx.conf

# create koreader-sync-server service directory and script
RUN mkdir -p /etc/service/koreader-sync-server && \
    echo -e "#!/bin/sh\ncd /app/koreader-sync-server\nexport GIN_PORT=8080\nexec gin start" > /etc/service/koreader-sync-server/run && \
    chmod +x /etc/service/koreader-sync-server/run

# Add healthcheck endpoint
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/healthcheck || exit 1

VOLUME ["/var/log/redis", "/var/lib/redis"]

# Use supervisor to manage processes
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
EXPOSE 8080
