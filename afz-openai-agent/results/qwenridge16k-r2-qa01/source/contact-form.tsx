"use client";

import { useState } from "react";

const PROJECT_TYPES = [
  "Commercial HVAC",
  "Institutional Building",
  "Kitchen Exhaust / Make-Up Air",
  "Hydronic Retrofit",
  "Gas Piping",
  "Plumbing",
  "Mechanical Permit",
  "Other",
];

const SERVICES = [
  "HVAC Design",
  "Heat Loss & Heat Gain",
  "Duct Design",
  "Ventilation",
  "Kitchen Exhaust & Make-Up Air",
  "Plumbing",
  "Hydronic Systems",
  "Gas Piping",
  "Mechanical Permits",
  "Multiple Services",
];

export default function ContactForm() {
  const [submitted, setSubmitted] = useState(false);

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSubmitted(true);
  };

  return (
    <form
      className="form"
      onSubmit={handleSubmit}
      aria-describedby="contact-heading"
    >
      <div className="form-grid">
        <div className="field">
          <label htmlFor="name">
            Name <span className="req" aria-hidden="true">*</span>
          </label>
          <input
            id="name"
            name="name"
            type="text"
            required
            autoComplete="name"
          />
        </div>

        <div className="field">
          <label htmlFor="company">Company</label>
          <input
            id="company"
            name="company"
            type="text"
            autoComplete="organization"
          />
        </div>

        <div className="field">
          <label htmlFor="email">
            Email <span className="req" aria-hidden="true">*</span>
          </label>
          <input
            id="email"
            name="email"
            type="email"
            required
            autoComplete="email"
          />
        </div>

        <div className="field">
          <label htmlFor="phone">Phone</label>
          <input
            id="phone"
            name="phone"
            type="tel"
            autoComplete="tel"
          />
        </div>

        <div className="field full">
          <label htmlFor="address">Project Address</label>
          <input
            id="address"
            name="address"
            type="text"
            autoComplete="street-address"
          />
          <span className="hint">
            City and province are helpful for municipal context.
          </span>
        </div>

        <div className="field">
          <label htmlFor="project-type">Project Type</label>
          <select id="project-type" name="project-type" defaultValue="">
            <option value="">Select a project type</option>
            {PROJECT_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </div>

        <div className="field">
          <label htmlFor="service">Service Required</label>
          <select id="service" name="service" defaultValue="">
            <option value="">Select a service</option>
            {SERVICES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </div>

        <div className="field full">
          <label htmlFor="description">Project Description</label>
          <textarea
            id="description"
            name="description"
            rows={5}
            placeholder="Describe the scope, timeline and any specific requirements."
          />
        </div>

        {submitted && (
          <p className="form-success" role="status">
            Thank you â€” your inquiry has been received. We will be in touch to
            discuss the next steps.
          </p>
        )}

        <div className="form-actions">
          <button type="submit" className="btn btn-primary">
            Submit Inquiry
          </button>
        </div>
      </div>
    </form>
  );
}