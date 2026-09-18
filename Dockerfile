# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.4.10
ARG NODE_VERSION=24.20.0
ARG NPM_VERSION=11.19.0
ARG PNPM_VERSION=12.3.4
ARG YARN_VERSION=4.18.0
ARG SUBJECT_UID=10001
ARG SUBJECT_GID=10001

FROM node:${NODE_VERSION}-slim AS node_runtime
ARG PNPM_VERSION
ARG YARN_VERSION
RUN npm install --global "pnpm@${PNPM_VERSION}" && \
    npm install --prefix /opt/yarn --omit=dev --no-package-lock "@yarnpkg/cli-dist@${YARN_VERSION}" && \
    YARN_BIN="$(node -p "require('/opt/yarn/node_modules/@yarnpkg/cli-dist/package.json').bin.yarn")" && \
    test "$(pnpm --version)" = "${PNPM_VERSION}" && \
    test "$(node "/opt/yarn/node_modules/@yarnpkg/cli-dist/${YARN_BIN}" --version)" = "${YARN_VERSION}"

FROM ruby:${RUBY_VERSION}-slim

ARG RUBY_VERSION
ARG NODE_VERSION
ARG NPM_VERSION
ARG PNPM_VERSION
ARG YARN_VERSION
ARG SUBJECT_UID
ARG SUBJECT_GID

WORKDIR /app

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development \
    RUNDIFF_EXECUTOR_CAPABILITIES_JSON="{\"runtimes\":{\"ruby\":\"${RUBY_VERSION}\",\"node\":\"${NODE_VERSION}\"},\"package_managers\":{\"npm\":\"${NPM_VERSION}\",\"pnpm\":\"${PNPM_VERSION}\",\"yarn\":\"${YARN_VERSION}\"}}" \
    RUNDIFF_SUBJECT_UID="${SUBJECT_UID}" \
    RUNDIFF_SUBJECT_GID="${SUBJECT_GID}" \
    RUNDIFF_SUBJECT_HOME="/home/rundiff-subject" \
    RUNDIFF_SUBJECT_USER="rundiff-subject"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      libsqlite3-dev \
      pkg-config && \
    groupadd --gid "${SUBJECT_GID}" rundiff-subject && \
    useradd --uid "${SUBJECT_UID}" --gid "${SUBJECT_GID}" --home-dir /home/rundiff-subject --create-home --shell /usr/sbin/nologin rundiff-subject && \
    rm -rf /var/lib/apt/lists/*

COPY --from=node_runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node_runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
COPY --from=node_runtime /usr/local/lib/node_modules/pnpm /usr/local/lib/node_modules/pnpm
COPY --from=node_runtime /opt/yarn /opt/yarn

RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    PNPM_BIN="$(node -p "require('/usr/local/lib/node_modules/pnpm/package.json').bin.pnpm")" && \
    PNPX_BIN="$(node -p "require('/usr/local/lib/node_modules/pnpm/package.json').bin.pnpx")" && \
    YARN_BIN="$(node -p "require('/opt/yarn/node_modules/@yarnpkg/cli-dist/package.json').bin.yarn")" && \
    ln -s "../lib/node_modules/pnpm/${PNPM_BIN}" /usr/local/bin/pnpm && \
    ln -s "../lib/node_modules/pnpm/${PNPX_BIN}" /usr/local/bin/pnpx && \
    ln -s "/opt/yarn/node_modules/@yarnpkg/cli-dist/${YARN_BIN}" /usr/local/bin/yarn && \
    test "$(node --version)" = "v${NODE_VERSION}" && \
    test "$(npm --version)" = "${NPM_VERSION}" && \
    test "$(pnpm --version)" = "${PNPM_VERSION}" && \
    test "$(yarn --version)" = "${YARN_VERSION}"

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .
RUN bundle exec ruby script/prove_node_npm_executor_capability.rb && \
    bundle exec ruby script/prove_pnpm_executor_capability.rb && \
    bundle exec ruby script/prove_yarn_berry_executor_capability.rb && \
    bundle exec ruby script/prove_http_service_lifecycle.rb && \
    bundle exec ruby script/prove_node_service_runtime.rb && \
    bundle exec ruby script/prove_production_compose_disabled.rb && \
    bundle exec ruby script/prove_subject_privilege_boundary.rb

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1

EXPOSE 3000

CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
