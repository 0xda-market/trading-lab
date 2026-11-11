# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT
FROM ruby:3.3.11-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile ./
RUN bundle config set --local without test && bundle install
COPY config.ru ./
COPY config/puma.rb config/puma.rb
COPY lib/ lib/
COPY db/ db/
COPY bin/ bin/

FROM ruby:3.3.11-slim
WORKDIR /app
ENV PORT=1927 RACK_ENV=production
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
USER 10001:10001
EXPOSE 1927
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
