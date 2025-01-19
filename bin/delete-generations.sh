#!/bin/bash

# Get the current time in seconds since epoch
current_time=$(date +%s)

# List all generations with their timestamps
nix-env --list-generations | while read -r line; do
  # Extract the generation number and timestamp
  generation=$(echo "$line" | awk '{print $1}')
  timestamp=$(echo "$line" | awk '{print $3 " " $4 " " $5 " " $6 " " $7}')

  # Convert the timestamp to seconds since epoch
  generation_time=$(date -d "$timestamp" +%s)

  # Calculate the age of the generation in seconds
  age=$((current_time - generation_time))

  # If the generation is older than 15 minutes (900 seconds), delete it
  if [ $age -gt 900 ]; then
    nix-env --delete-generations $generation
  fi
done

# Run garbage collection to remove unused derivations
nix-collect-garbage -d