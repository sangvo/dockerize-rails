FILES = {
  DOCKERFILE: 'Dockerfile.dev',
  DOCKER_COMPOSE: 'docker-compose.yml',
  DOCKER_IGNORE: '.dockerignore',
  ENTRYPOINT_SCRIPT: 'entrypoint.sh',
  DATABASE_FILE: 'config/database.yml'
}.freeze

puts FILES.values
return if no?('The above files will be overwritten / created. Is this okay? (yes / no):')

run "touch #{FILES.values.join(' ')}"

APP_NAME = app_name
RUBY_VERSION = '3.1'
POSTGRES_VERSION = '14'
APP_DIR = '/app'
USER = 'rails'

PORTS = { RAILS: '3000' }.freeze

DATABASE_USER = 'postgres'
DATABASE_PASSWORD = 'password'

# Create package.json file
unless File.exist?('package.json')
  create_file 'package.json',
              <<~JSON
                {
                  "name": "#{APP_NAME}",
                  "private": "true"
                }
              JSON
  run 'yarn install'
end

create_file FILES[:DOCKERFILE] do
  <<~EOF
    # Pre setup stuff
    FROM ruby:#{RUBY_VERSION} as builder

    ENV LANG C.UTF-8
    ENV APP_ROOT #{APP_DIR}

    # Add Yarn to the repository
    RUN curl https://deb.nodesource.com/setup_18.x | bash && \\
        curl https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \\
        echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list

    # Install system dependencies & clean them up
    # libnotify-dev is what allows you to watch file changes w/ HMR
    RUN apt-get update -qq && apt-get install -y \\
        postgresql-client build-essential yarn nodejs \\
        libnotify-dev && \\
        rm -rf /var/lib/apt/lists/*

    # This is where we build the rails app
    FROM builder as rails-app

    # create working directory
    RUN mkdir $APP_ROOT
    WORKDIR $APP_ROOT

    # Install rails related dependencies
    COPY Gemfile $APP_ROOT/Gemfile
    COPY Gemfile.lock $APP_ROOT/Gemfile.lock

    # Fix an issue with outdated bundler
    RUN gem install "bundler:~>2" --no-document && \
    gem update --system && \
    gem cleanup

    RUN bundle install

    # Copy over all files
    COPY . $APP_ROOT

    RUN yarn install --check-files

    # Remove existing running server
    COPY entrypoint.sh /usr/bin/
    RUN chmod +x /usr/bin/#{FILES[:ENTRYPOINT_SCRIPT]}
    ENTRYPOINT ["/usr/bin/#{FILES[:ENTRYPOINT_SCRIPT]}"]

    # Allow access to port 3000
    EXPOSE #{PORTS[:RAILS]}

    # Start the main process.
    CMD ["rails", "server", "-p", "#{PORTS[:RAILS]}", "-b", "0.0.0.0"]
  EOF
end

create_file FILES[:DOCKER_COMPOSE] do
  <<~EOF
    version: '3.2'

    services:
      web:
        environment:
          NODE_ENV: development
          RAILS_ENV: development
          POSTGRES_USER: #{DATABASE_USER}
          POSTGRES_PASSWORD: #{DATABASE_PASSWORD}

        build:
          context: .
          dockerfile: #{FILES[:DOCKERFILE]}
          args:
            APP_DIR: #{APP_DIR}

        command: bash -c "rm -f tmp/pids/server.pid &&
                          bundle exec rails server -p #{PORTS[:RAILS]} -b '0.0.0.0'"

        volumes:
          # make sure this lines up with APP_DIR above
          - .:#{APP_DIR}:cached
          - node_modules:#{APP_DIR}/node_modules
          - rails_cache:/app/tmp/cache

        ports:
          - "#{PORTS[:RAILS]}:#{PORTS[:RAILS]}"

        stdin_open: true
        tty: true
        depends_on:
          - db

      db:
        image: postgres:#{POSTGRES_VERSION}
        environment:
          POSTGRES_PASSWORD: #{DATABASE_PASSWORD}
          PSQL_HISTFILE: /user/local/hist/.psql_history
        volumes:
          - postgres:/var/lib/postgresql/data

    volumes:
      postgres:
      node_modules:
      rails_cache:

  EOF
end

create_file FILES[:DOCKER_IGNORE] do
  <<~EOF
    # Ignore bundler config.
    /.bundle

    # Ignore all logfiles and tempfiles.
    /log/*
    /tmp/*
    !/log/.keep
    !/tmp/.keep

    # Ignore pidfiles, but keep the directory.
    /tmp/pids/*
    !/tmp/pids/
    !/tmp/pids/.keep

    # Ignore uploaded files in development.
    /storage/*
    !/storage/.keep

    /public/assets
    .byebug_history

    # Ignore master key for decrypting credentials and more.
    /config/master.key

    /public/packs
    /public/packs-test
    /node_modules
    !/node_modules/.yarn-integrity
    /yarn-error.log
    yarn-debug.log*
    .git
  EOF
end

create_file FILES[:ENTRYPOINT_SCRIPT] do
  <<~EOF
    #!/bin/bash

    set -e

    # Remove a potentially pre-existing server.pid for Rails.
    rm -f /app/tmp/pids/server.pid

    # Then exec the container's main process (what's set as CMD in the Dockerfile).
    exec "$@"
  EOF
end

create_file FILES[:DATABASE_FILE] do
  <<~EOF
    default: &default
      adapter: postgresql
      encoding: unicode
      host: db
      username: <%= ENV['POSTGRES_USER'] %>
      password: <%= ENV['POSTGRES_PASSWORD'] %>
      pool: 5

    development:
      <<: *default
      database: #{APP_NAME}_development

    test:
      <<: *default
      database: #{APP_NAME}_test
  EOF
end
