# syntax=docker/dockerfile:1

FROM ruby:3.3-slim

ENV APP_HOME=/opt/rubydb \
    RUBYDB_DATA_DIR=/var/lib/rubydb/data \
    RUBYDB_LOG_DIR=/var/log/rubydb \
    RUBYDB_PID_FILE=/run/rubydb.pid \
    RUBYDB_HOST=0.0.0.0 \
    RUBYDB_PORT=7432

WORKDIR ${APP_HOME}

COPY Gemfile Gemfile.lock rubydb.gemspec ./
COPY lib ./lib
COPY exe ./exe
COPY bin ./bin

RUN bundle config set --without development:test \
    && bundle install --jobs 4 --retry 3 \
    && gem build rubydb.gemspec \
    && gem install --no-document rubydb-*.gem \
    && rm -f rubydb-*.gem \
    && useradd --system --home-dir ${APP_HOME} --shell /usr/sbin/nologin rubydb \
    && install -d -o rubydb -g rubydb ${RUBYDB_DATA_DIR} ${RUBYDB_LOG_DIR} /run/rubydb

COPY packaging/docker/entrypoint.sh /usr/local/bin/rubydb-entrypoint
RUN chmod 0755 /usr/local/bin/rubydb-entrypoint

USER rubydb
EXPOSE 7432
VOLUME ["/var/lib/rubydb"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD rubydb status --json >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/rubydb-entrypoint"]
