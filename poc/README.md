# PoC Directory

This directory contains exploratory prototypes.

It is public on purpose, but it is not the source of truth for the sealed release claim.

## Purpose

Use this directory for:

- early economic experiments
- protocol-specific SDK exploration
- fast feasibility checks before hardening logic into `scripts/` or `sui/`

## What Lives Here

- `economics/`
  - parameter and return-shape exploration
- `aftermath-perps/`
  - protocol-specific SDK feasibility work for perps

## How To Read It

- start with this file
- then read the subdirectory README that matches the prototype area
- treat PoC results as directional inputs, not sealed-release evidence

## Boundary

Do not use this directory as evidence for the sealed release artifact.

The public source-of-truth areas are:

- `README.md`
- `sui/`
- `scripts/`
- `formal/`
- `reference/`
