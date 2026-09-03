import type { Metadata } from "next";
import ContactForm from "@/components/ContactForm";

export const metadata: Metadata = {
  title: "Contact",
  description:
    "Contact AFZ Engineering Inc. to start a mechanical project. Share your name, company, contact details, project address, project type, service required and description.",
};

export default function ContactPage() {
  return (
    <>
      <section className="page-hero">
        <div className="container">
          <h1>Start a Project</h1>
          <p>
            Tell us about your project and we will outline how we can help with
            mechanical design, coordination and permitting.
          </p>
        </div>
      </section>

      <section className="section" aria-labelledby="contact-heading">
        <div className="container">
          <div className="section-head">
            <h2 id="contact-heading">Project inquiry</h2>
            <p>
              Complete the form below. Fields marked with an asterisk are
              required.
            </p>
          </div>
          <ContactForm />
        </div>
      </section>
    </>
  );
}