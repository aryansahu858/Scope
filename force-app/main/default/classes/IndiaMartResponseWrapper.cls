public class IndiaMartResponseWrapper {
    public Integer CODE;
    public String STATUS;
    public String MESSAGE;
    public Integer TOTAL_RECORDS;
    public List<LeadDetail> RESPONSE;

    public class LeadDetail {
        public String UNIQUE_QUERY_ID;
        public String QUERY_TYPE;
        public String SENDER_NAME;
        public String SENDER_MOBILE;
        public String SENDER_EMAIL;
        public String SUBJECT;
        public String SENDER_COMPANY;
        public String SENDER_CITY;
        public String SENDER_STATE;
        public String SENDER_PINCODE;
        public String SENDER_COUNTRY_ISO;
        public String SENDER_PHONE;
        public String QUERY_PRODUCT_NAME;
        public String QUERY_MESSAGE;
        public String QUERY_MCAT_NAME;
    }
}