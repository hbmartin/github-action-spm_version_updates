FROM ruby:3.3-alpine

# Install git and build dependencies for native gems
RUN apk add --no-cache git build-base

# Set working directory
WORKDIR /action

# Copy Gemfile and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test

# Copy source code
COPY lib/ ./lib/
COPY entrypoint.sh ./

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Set entrypoint
ENTRYPOINT ["/action/entrypoint.sh"]

