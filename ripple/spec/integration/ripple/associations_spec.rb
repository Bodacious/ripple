require 'spec_helper'

describe "Ripple Associations" do
  require 'support/test_server'

  before :all do
    Object.module_eval do
      class User
        include Ripple::Document
        one  :profile
        many :addresses
        property :email, String, :presence => true
        many :friends, :class_name => "User"
        one :emergency_contact, :class_name => "User"
        one :credit_card, :using => :key
      end
      class Profile
        include Ripple::EmbeddedDocument
        property :name, String, :presence => true
        embedded_in :user
      end
      class Address
        include Ripple::EmbeddedDocument
        property :street, String, :presence => true
        property :kind,   String, :presence => true
        embedded_in :user
      end
      class CreditCard
        include Ripple::Document
        one :user, :using => :key
        property :number, Integer
      end
      class Post
        include Ripple::Document
        one :user, :using => :stored_key
        many :comments, :using => :stored_key
        property :comment_keys, Array
        property :user_key, String
        property :title, String
      end
      class Comment
        include Ripple::Document
      end
    end
  end

  before :each do
    @user        = User.new(:email => 'riak@ripple.com')
    @profile     = Profile.new(:name => 'Ripple')
    @billing     = Address.new(:street => '123 Somewhere Dr', :kind => 'billing')
    @shipping    = Address.new(:street => '321 Anywhere Pl', :kind => 'shipping')
    @friend1     = User.create(:email => "friend@ripple.com")
    @friend2     = User.create(:email => "friend2@ripple.com")
    @cc          = CreditCard.new(:number => '12345')
    @post        = Post.new(:title => "Hello, world!")
    @comment_one = Comment.new.tap{|c| c.key = "one"; c.save! }
    @comment_two = Comment.new.tap{|c| c.key = "two"; c.save! }
  end

  it "should save and restore a many stored key association" do
    @post.comments << @comment_one << @comment_two
    @post.save!

    post = Post.find(@post.key)
    post.comment_keys.should == [ 'one', 'two' ]
    post.comments.keys.should == [ 'one', 'two' ]
    post.comments.should == [ @comment_one, @comment_two ]
  end

  it "should remove a document from a many stored key association" do
    @post.comments << @comment_one
    @post.comments << @comment_two
    @post.save!
    @post.comments.delete(@comment_one)
    @post.save!

    @post = Post.find(@post.key)
    @post.comment_keys.should == [ @comment_two.key ]
    @post.comments.should == [ @comment_two ]
  end

  it "should save one embedded associations" do
    @user.profile = @profile
    @user.save
    @found = User.find(@user.key)
    @found.profile.name.should == 'Ripple'
    @found.profile.should be_a(Profile)
    @found.profile.user.should == @found
  end

  it "should not raise an error when a one linked associated record has been deleted" do
    @user.emergency_contact = @friend1
    @user.save

    @friend1.destroy
    @found = User.find(@user.key)
    @found.emergency_contact.should be_nil
  end

  it "should allow a many linked record to be deleted from the association but kept in the datastore" do
    @user.friends << @friend1
    @user.save!

    @user.friends.delete(@friend1)
    @user.save!

    found_user = User.find(@user.key)
    found_user.friends.should be_empty
    User.find(@friend1.key).should be
  end

  it "should allow a many embedded record to be deleted from the association" do
    @user.addresses << @billing << @shipping
    @user.save!

    @user.addresses.delete(@billing)
    @user.save!
    User.find(@user.key).addresses.should == [@shipping]
  end

  it "should save many embedded associations" do
    @user.addresses << @billing << @shipping
    @user.save
    @found = User.find(@user.key)
    @found.addresses.count.should == 2
    @bill = @found.addresses.detect {|a| a.kind == 'billing'}
    @ship = @found.addresses.detect {|a| a.kind == 'shipping'}
    @bill.street.should == '123 Somewhere Dr'
    @ship.street.should == '321 Anywhere Pl'
    @bill.user.should == @found
    @ship.user.should == @found
    @bill.should be_a(Address)
    @ship.should be_a(Address)
  end

  it "should save a many linked association" do
    @user.friends << @friend1 << @friend2
    @user.save
    @user.should_not be_new_record
    @found = User.find(@user.key)
    @found.friends.map(&:key).should include(@friend1.key)
    @found.friends.map(&:key).should include(@friend2.key)
  end

  it "should save a one linked association" do
    @user.emergency_contact = @friend1
    @user.save
    @user.should_not be_new_record
    @found = User.find(@user.key)
    @found.emergency_contact.key.should == @friend1.key
  end

  it "should reload associations" do
    @user.friends << @friend1
    @user.save!

    friend1_new_instance = User.find(@friend1.key)
    friend1_new_instance.email = 'new-address@ripple.com'
    friend1_new_instance.save!

    @user.reload
    @user.friends.map(&:email).should == ['new-address@ripple.com']
  end

  it "allows and autosaves transitive linked associations" do
    friend = User.new(:email => 'user-friend@example.com')
    friend.key = 'main-user-friend'
    @user.key = 'main-user'
    @user.friends << friend
    friend.friends << @user

    @user.save! # should save both since friend is new

    found_user = User.find!(@user.key)
    found_friend = User.find!(friend.key)

    found_user.friends.should == [found_friend]
    found_friend.friends.should == [found_user]
  end

  it "should find the object associated by key after saving" do
    @user.key = 'paying-user'
    @user.credit_card = @cc
    @user.save && @cc.save
    @found = User.find(@user.key)
    @found.reload
    @found.credit_card.should eq(@cc)
  end

  it "should assign the generated riak key to the associated object using key" do
    @user.key.should be_nil
    @user.credit_card = @cc
    @user.save
    @cc.key.should_not be_blank
    @cc.key.should eq(@user.key)
  end

  it "should save one association by storing key" do
    @user.save!
    @post.user = @user
    @post.save!
    @post.user_key.should == @user.key
    @found = Post.find(@post.key)
    @found.user.email.should == 'riak@ripple.com'
    @found.user.should be_a(User)
  end

  after :each do
    User.destroy_all
  end

  after :all do
    Object.send(:remove_const, :User)
    Object.send(:remove_const, :Profile)
    Object.send(:remove_const, :Address)
    Object.send(:remove_const, :CreditCard)
    Object.send(:remove_const, :Post)
  end

end
